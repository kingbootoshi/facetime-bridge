# ADR-0017: Call recording is explicit, local, and non-fatal

Status: Accepted

## Decision

The native daemon records no audio unless `FACETIME_BRIDGE_RECORDINGS_DIR` is set to an absolute local directory. When enabled, each call gets a private `0700` directory with separate 24 kHz mono PCM16 `caller.wav` and `agent.wav` files at mode `0600`.

Recording sits at the native audio boundary. It captures caller PCM before gRPC delivery and agent PCM before playback, so audio already observed survives a provider or agent failure. The bridge never uploads recordings and never includes caller identity in paths or filenames.

A recording write failure disables recording for that call and logs the failure. It never stops capture, playback, call control, or the provider stream. The WAV header is finalized on every normal stream exit and on teardown.

## Enforcement

The native self-check writes both channels, validates RIFF data lengths, forces a write-after-close failure, and proves that the recorder disables itself without throwing into the audio stream. Directory and file modes are set at creation. Missing `FACETIME_BRIDGE_RECORDINGS_DIR` keeps recording disabled.
