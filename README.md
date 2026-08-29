# facetime-bridge

<p align="center">
  <img src="assets/facetime-bridge-hero.jpeg" alt="Vibe Bot connecting verified incoming and outgoing FaceTime audio paths" width="960">
</p>

A local macOS bridge for strict FaceTime Audio control and provider-neutral two-way audio.

It provides:

- semantic Accessibility control for `probe`, `call`, and `answer`
- exact E.164 caller authorization bound to the action-owning call card
- deterministic setup and a read-only doctor
- verified official BlackHole 2ch and 16ch prerequisites
- a browser `MediaStream` bridge with no bundled AI provider

It does not sign in to iCloud, bypass macOS permissions, or send credentials or audio to a service. Local call recording is off unless explicitly enabled.

## Requirements

- macOS with FaceTime Audio available
- an iCloud account signed in to FaceTime
- [Bun](https://bun.sh)
- [Homebrew](https://brew.sh)
- a Chromium-based browser with `MediaStreamTrackProcessor`, `MediaStreamTrackGenerator`, `AudioData`, `setSinkId`, and Web Locks
- manual approval for Accessibility and microphone access

A dedicated iCloud account for the Mac that hosts the automation is recommended. Confirm a normal FaceTime Audio call before you enable automation.

## Install

```bash
git clone https://github.com/kingbootoshi/facetime-bridge.git
cd facetime-bridge
# Apple silicon. Use /usr/local/bin/brew on Intel.
/opt/homebrew/bin/brew install --cask blackhole-2ch blackhole-16ch
FACETIME_BRIDGE_AUTHORIZED_CALLER_E164='+15550101001' bun run src/cli.ts setup
```

The setup command:

1. Requires `FACETIME_BRIDGE_AUTHORIZED_CALLER_E164` to contain one exact E.164 phone number before mutation.
2. Uses the fixed Homebrew path for the current architecture.
3. Verifies both installed casks come from `homebrew/cask`.
4. Stops before mutation when either cask is missing and prints an explicit command for only the missing cask.
5. Builds the `native/` Swift package in release mode and atomically installs its `facetime-bridge` executable as `~/.local/bin/facetime-bridge-ax`.
6. Creates `~/.local/bin/facetime-bridge`, which imports this checkout's `src/cli.ts`. Keep the checkout at a permanent path.
7. Writes no caller identity file and prints the remaining manual macOS steps.

BlackHole's official installation command is:

```bash
brew install --cask blackhole-2ch blackhole-16ch
```

BlackHole is not bundled with this project. Read its [upstream license and installation guide](https://github.com/ExistentialAudio/BlackHole) before use.

## Manual macOS setup

1. Sign in to FaceTime yourself.
2. Make a normal FaceTime Audio call.
3. Open **System Settings → Privacy & Security → Accessibility**.
4. Add and enable `~/.local/bin/facetime-bridge-ax`.
5. Allow the browser that opens the audio workbench to use the microphone when macOS asks.
6. In FaceTime, select **BlackHole 16ch** for call output.
7. In FaceTime, select **BlackHole 2ch** for the microphone.
8. Run the doctor.

```bash
FACETIME_BRIDGE_AUTHORIZED_CALLER_E164='+15550101001' bun run src/cli.ts doctor
```

The doctor fails until every required fact is available. It verifies both BlackHole devices as virtual input/output devices with the expected channel count at 48 kHz.

## Caller authority

The only caller authority is this process environment variable:

```text
FACETIME_BRIDGE_AUTHORIZED_CALLER_E164
```

It must contain one exact E.164 phone number: `+`, a nonzero country-code digit, and 7–14 more digits. Email addresses, contact names, whitespace, national-number suffixes, and every other form fail closed.

Inject the variable into every setup, doctor, and installed native executable process. For a direct one-shot invocation:

```bash
FACETIME_BRIDGE_AUTHORIZED_CALLER_E164='+15550101001' facetime-bridge doctor
FACETIME_BRIDGE_AUTHORIZED_CALLER_E164='+15550101001' facetime-bridge probe
```

A private deployment may map a vault key with this exact name into the process through `sv run`. This public repository does not install, import, or invoke `sv`; it only reads the injected variable. The bridge never persists the caller number.

## CLI

```bash
facetime-bridge setup
facetime-bridge doctor
facetime-bridge probe
facetime-bridge call
facetime-bridge answer
facetime-bridge hangup
facetime-bridge audio
```

During development, use:

```bash
bun run src/cli.ts <command>
```

Control commands emit one strict JSON object. A failed authorization or an ambiguous Accessibility surface returns a non-zero exit status.

The Bun CLI delegates each control command to `~/.local/bin/facetime-bridge-ax`. That installed Swift package executable implements the same direct commands; with no arguments it starts the local gRPC daemon.

### Security behavior

- `call` opens only the authorized E.164 number. It presses only one Notification Center action whose action-owning card contains the exact full E.164 or its full digit-normalized form and `Click to Call`.
- `answer` presses only one incoming action whose action-owning card contains that same exact identity. Contact labels, email addresses, and national-number suffixes never authorize.
- Multiple exact action matches fail with `AMBIGUOUS_ACTION`.
- `hangup` requires a live call authority: a pid-bound in-process token granted only by an identity-verified `answer` or `call` press. It gracefully terminates only that bound Phone process (macOS exposes no reachable semantic hangup control once the call banner disappears) and refuses with `NO_AUTHORIZED_CALL` otherwise.
- No command uses coordinate clicks.
- Missing, unknown, or ambiguous UI state fails closed.

Apple can change private FaceTime UI and Accessibility labels. This project treats such changes as unavailable behavior instead of guessing.

## Plug in your voice software

The bridge owns FaceTime alone; you bring the AI. One gRPC surface
(`facetimebridge.v1` over a Unix socket) carries call control, call events,
and bidirectional 24 kHz PCM. A typed TypeScript base adapter ships at
[`src/bridge.ts`](src/bridge.ts), and the proto works from any language —
including Python voice stacks like [Pipecat](https://github.com/pipecat-ai/pipecat).

**Read [`docs/INTEGRATION.md`](docs/INTEGRATION.md)** — the complete
contract: audio format, call lifecycle, fail-closed authority codes, a
TypeScript quickstart, and a Pipecat transport recipe. If you are an agent
integrating this bridge, that file is your single entry point.

## Provider-neutral audio

Start the local workbench:

```bash
facetime-bridge audio
```

It opens `http://127.0.0.1:5612/` in your default browser. The page fails closed when the required Chromium media APIs are unavailable.

The browser module exports `FaceTimeAudioBridge`:

```js
import { FaceTimeAudioBridge } from "./facetime-audio-bridge.js";

const bridge = await FaceTimeAudioBridge.open();

// Send the verified FaceTime caller audio to any local or remote consumer.
provider.consume(bridge.incomingStream);

// Route any returned audio MediaStream into the FaceTime microphone.
await bridge.routeOutgoing(provider.outputStream);

await bridge.stop();
```

Replace `provider` with your own speech system, recorder, media processor, or peer connection. This repository includes no provider client, token handling, WebSocket, prompt, or agent.

### Audio contract

```text
Incoming caller
FaceTime output → BlackHole 16ch → 48 kHz stereo frames
→ frame-level stereo-to-mono conversion
→ verified 48 kHz mono MediaStream → your consumer

Outgoing producer
Your MediaStream → exact BlackHole 2ch sink
→ FaceTime microphone → remote caller
```

The bridge:

- selects exact BlackHole devices
- disables echo cancellation, noise suppression, and automatic gain control
- proves a real 48 kHz mono `AudioData` frame before returning
- uses a browser singleton lock so a second tab cannot create a second agent response
- stops source tracks, generated tracks, output playback, and the singleton lock during teardown

The included workbench displays incoming audio level and can send a one-second local test tone. It does not record or upload audio.

### Optional local WAV fallback

Set `FACETIME_BRIDGE_RECORDINGS_DIR` to an absolute local directory before starting the native daemon. Each call then creates one private directory containing:

- `caller.wav` — 24 kHz mono PCM16 received from the caller
- `agent.wav` — 24 kHz mono PCM16 sent back to the call

Directories use mode `0700`; files use mode `0600`. Paths contain no caller identity. The bridge never uploads recordings. A disk write failure disables recording for that call without interrupting capture, playback, or call control. See [ADR-0017](docs/adr/0017-opt-in-local-call-recording.md).

## Uninstall

1. Remove Accessibility permission for `~/.local/bin/facetime-bridge-ax`.
2. Remove browser microphone permission if it was granted only for this bridge.
3. Delete `~/.local/bin/facetime-bridge-ax` and `~/.local/bin/facetime-bridge`.
4. Restore the prior FaceTime input and output devices.
5. Remove only BlackHole casks that are not used by another audio workflow.
6. Delete the source checkout after deleting the checkout-linked launcher.

## Development

```bash
bun test
bun build src/cli.ts --target=bun --outfile=dist/facetime-bridge.js
```

Build the native package directly:

```bash
xcrun swift build \
  --package-path native \
  -c release \
  --product facetime-bridge
```

The release executable is `native/.build/release/facetime-bridge`. Run it with `probe`, `call`, `answer`, or `hangup` for the strict control JSON contract, or with no arguments for daemon mode.

## License

The code in this repository is MIT licensed.

BlackHole is a separate project with its own GPLv3 and commercial licensing terms. This repository does not copy or distribute BlackHole source code or binaries.

<p align="center">
  <a href="https://bootoshi.ai/">bootoshi.ai</a>
  ·
  <a href="https://discord.gg/invite/vcu">Discord</a>
</p>
