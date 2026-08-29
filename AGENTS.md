# Repository instructions

Read `docs/adr/README.md` before non-trivial changes.

- Use Bun for TypeScript commands and tests.
- Inject caller authority only through `FACETIME_BRIDGE_AUTHORIZED_CALLER_E164`; accept exact E.164 values and fail closed.
- Never commit local configuration, credentials, recordings, logs, device identifiers, or personal data.
- Keep FaceTime control semantic and fail closed. Do not add coordinate clicks.
- Keep audio provider-neutral. Do not add a bundled provider, token path, or hosted dependency.
- Preserve the one-session audio lock and verified teardown.
