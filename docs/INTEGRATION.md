# Plugging your voice stack into facetime-bridge

This document is the complete integration contract. If you are an agent
building on this bridge, read this file top to bottom; everything you need
is here or linked from here.

## What the bridge owns (and what you own)

The bridge owns **FaceTime alone**: placing, answering, and ending FaceTime
Audio calls on a Mac, plus moving raw call audio in both directions. It
bundles **no AI provider, no ASR, no TTS**. You bring the voice software —
Pipecat, a realtime speech model, your own pipeline — and speak to the
bridge over one gRPC surface.

```
caller ──FaceTime Audio──> macOS ──BlackHole──> facetime-bridge daemon
                                                      │  gRPC over unix socket
                                                      ▼
                                             your voice software
```

## The canonical adapter surface is the proto

[`native/Sources/FaceTimeBridge/Protos/facetime_media.proto`](../native/Sources/FaceTimeBridge/Protos/facetime_media.proto)
— package `facetimebridge.v1`, service `FaceTimeMedia`, four RPCs:

| RPC | Shape | Purpose |
|---|---|---|
| `Health` | unary | daemon readiness + bound BlackHole devices |
| `Control` | unary | `PROBE` / `CALL` / `ANSWER` / `HANGUP` |
| `WaitIncoming` | server stream | call-state transitions (`ringing`, `connected`, `ended`, ...) |
| `Audio` | bidi stream | raw PCM both directions |

Any language with gRPC support integrates directly from that one file.
The daemon listens on a Unix socket: `~/.facetime-bridge/bridge.sock`
(override with `FACETIME_BRIDGE_SOCKET`).

## Audio contract

- **Format:** 24 kHz, mono, signed 16-bit little-endian PCM (`s16le`).
- **Cadence:** ~100 ms packets → 2,400 samples → 4,800 bytes each.
- **Direction is the packet `kind`:**
  - `CAPTURE` (2) — caller's voice, daemon → you.
  - `PLAYBACK` (3) — your agent's voice, you → daemon.
  - `START` (1) / `STOP` (5) — session framing from the daemon.
  - `CLEAR` (4) — flush queued playback immediately (send this for barge-in).
  - `EVENT` (6) — out-of-band notices in the `event` field.
- Set `call_id`, `sample_rate: 24000`, `channels: 1` on packets you send.

## Call lifecycle

1. `Health` → wait for `ready: true`.
2. `WaitIncoming` → stream events. On `state: "ringing"` with
   `authorized: true`, send `Control(ANSWER)`.
   Outbound instead: `Control(CALL)`.
3. Open `Audio`; on connect, consume `CAPTURE` packets and write `PLAYBACK`
   packets.
4. The daemon presses hangup via `Control(HANGUP)`, or the far side ends the
   call; either way you receive `state: "ended"` and the audio stream stops.

## Fail-closed authority (do not work around this)

The daemon only acts on calls matching one configured E.164 identity,
injected as `FACETIME_BRIDGE_AUTHORIZED_CALLER_E164` at daemon start
(recommended: from a secrets runner, never a file). Unconfigured, ambiguous,
or mismatched callers are refused with a named `error_code`
(`CALLER_NOT_AUTHORIZED`, `AMBIGUOUS_ACTION`, `NO_AUTHORIZED_CALL`, ...).
Your adapter should surface these codes verbatim, never retry around them.
Display names never authorize; only the configured handle does.

Optional local recording: set `FACETIME_BRIDGE_RECORDINGS_DIR` to an
absolute path and each call writes private `caller.wav` / `agent.wav`
(see [ADR-0017](adr/0017-opt-in-local-call-recording.md)).

## TypeScript base adapter (bundled)

[`src/bridge.ts`](../src/bridge.ts) exports `FaceTimeBridge` — a thin,
typed client over the proto. It is the reference implementation of this
document and runs in Bun.

```ts
import { FaceTimeBridge, audioPacketKind, audioFormat } from "facetime-bridge/src/bridge.ts";

const bridge = new FaceTimeBridge();
const { ready } = await bridge.health();
if (!ready) throw new Error("bridge daemon is not ready");

// Answer the next authorized call, then wire audio.
for await (const event of bridge.waitIncoming()) {
  if (event.state === "ringing" && event.authorized) {
    const reply = await bridge.control("answer");
    if (!reply.ok) throw new Error(`${reply.errorCode}: ${reply.message}`);
  }
  if (event.state === "connected") break;
  if (event.state === "ended") process.exit(0);
}

const audio = bridge.audio();
audio.on("data", (packet) => {
  if (packet.kind === audioPacketKind.capture) {
    // packet.pcm16: caller voice, audioFormat.sampleRate mono s16le.
    // Feed your ASR / realtime model here.
  }
});
// Speak: write playback packets produced by your TTS / realtime model.
audio.write({
  callId: "",
  kind: audioPacketKind.playback,
  pcm16: myPcmChunk, // 24 kHz mono s16le
  sampleRate: audioFormat.sampleRate,
  channels: audioFormat.channels,
  sequence: 0,
  event: "",
});
```

## Pipecat adapter (Python)

Pipecat is Python-first, so it consumes the proto directly — no TypeScript
required. The bridge maps onto a Pipecat **transport**:

- Generate stubs: `python -m grpc_tools.protoc -I native/Sources/FaceTimeBridge/Protos --python_out=. --grpc_python_out=. facetime_media.proto`
- Connect `grpc.aio.insecure_channel("unix:" + os.path.expanduser("~/.facetime-bridge/bridge.sock"))`.
- **Input:** each `CAPTURE` packet becomes an `InputAudioRawFrame(audio=pkt.pcm16, sample_rate=24000, num_channels=1)` pushed into the pipeline.
- **Output:** consume `OutputAudioRawFrame`s from the pipeline, resample to 24 kHz mono if your TTS emits another rate, and send them as `PLAYBACK` packets.
- **Interruption:** when Pipecat signals user-started-speaking, send one `CLEAR` packet before new playback so stale agent audio drops instantly.
- **Lifecycle:** `WaitIncoming` drives transport start/stop — start the pipeline on `connected`, tear down on `ended`.

Skeleton:

```python
class FaceTimeBridgeTransport(BaseTransport):
    """Pipecat transport backed by the facetime-bridge daemon."""
    # input():  Audio stream CAPTURE  -> InputAudioRawFrame (24 kHz mono s16le)
    # output(): OutputAudioRawFrame   -> Audio stream PLAYBACK
    # clear on interruption; Control(ANSWER/HANGUP) from WaitIncoming events
```

Keep the transport dumb: authority, call state, and device binding all live
in the daemon. If the daemon refuses, your pipeline never started — that is
the contract working, not a bug.

## Ground truth

This exact surface carried a live machine-answered FaceTime Audio call
end-to-end (ring → authorized answer → bidirectional audio → clean hangup)
with every capture byte accounted for in the recording tee. The TypeScript
adapter above is the same code that ran that call.
