# facetime-bridge

<p align="center">
  <img src="assets/facetime-bridge-hero.jpeg" alt="Vibe Bot connecting verified incoming and outgoing FaceTime audio paths" width="960">
</p>

A local macOS bridge for strict FaceTime Audio control and provider-neutral two-way audio.

It provides:

- semantic Accessibility control for `probe`, `call`, and `answer`
- exact configured-handle authorization bound to the action node
- an interactive setup and read-only doctor
- verified official BlackHole 2ch and 16ch prerequisites
- a browser `MediaStream` bridge with no bundled AI provider

It does not sign in to iCloud, bypass macOS permissions, record calls, or send credentials to a service.

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
bun run src/cli.ts setup
```

The setup wizard:

1. Checks Homebrew.
2. Offers to run the official BlackHole installation only after you approve it.
3. Installs `blackhole-2ch` and `blackhole-16ch` through Homebrew.
4. Compiles the Swift helper to `~/.local/bin/facetime-bridge-ax`.
5. Writes `~/.config/facetime-bridge/config.json` with mode `0600`.
6. Prints the remaining manual macOS steps.

BlackHole's official installation commands are:

```bash
brew install blackhole-2ch blackhole-16ch
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
bun run src/cli.ts doctor
```

The doctor fails until every required fact is available. It verifies both BlackHole devices as virtual input/output devices with the expected channel count at 48 kHz.

## Configuration

The setup wizard owns this local file:

```text
~/.config/facetime-bridge/config.json
```

Schema:

```json
{
  "targetHandle": "user@example.com",
  "targetName": "Example User",
  "blackHole2chLabel": "BlackHole 2ch",
  "blackHole16chLabel": "BlackHole 16ch"
}
```

`targetHandle` must be an E.164 phone number or email address. Automatic control requires that exact handle on the same Accessibility node as the action. `targetName` is corroborating configuration only and never authorizes an action by itself. The audio labels are optional overrides.

The file must be owned by the current user, must not be a symbolic link, and must have mode `0600`. Missing or unsafe configuration blocks control actions.

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

### Security behavior

- `call` opens only the configured handle. It presses only one Notification Center action whose same Accessibility node contains the exact configured email or E.164 handle and `Click to Call`.
- `answer` presses only one incoming Notification Center action whose same node contains the exact configured handle. It does not authorize from the display name alone.
- Multiple exact action matches fail with `AMBIGUOUS_ACTION`.
- `hangup` is disabled with `HANGUP_DISABLED` until a stable semantic Accessibility action is verified. It never terminates the Phone process.
- No command uses coordinate clicks.
- Missing, unknown, or ambiguous UI state fails closed.

Apple can change private FaceTime UI and Accessibility labels. This project treats such changes as unavailable behavior instead of guessing.

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


## Development

```bash
bun test
bun build src/cli.ts --target=bun --outfile=dist/facetime-bridge.js
```

Compile the native helper directly:

```bash
xcrun swiftc \
  native/Types.swift \
  native/AXTraversal.swift \
  native/StateClassifier.swift \
  native/Actions.swift \
  native/main.swift \
  -framework AppKit \
  -framework ApplicationServices \
  -o facetime-bridge-ax
```

## License

The code in this repository is MIT licensed.

BlackHole is a separate project with its own GPLv3 and commercial licensing terms. This repository does not copy or distribute BlackHole source code or binaries.

<p align="center">
  <a href="https://bootoshi.ai/">bootoshi.ai</a>
  ·
  <a href="https://discord.gg/invite/vcu">Discord</a>
</p>
