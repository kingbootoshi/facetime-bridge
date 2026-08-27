# Repository instructions

Read `docs/adr/README.md` before non-trivial changes.

- Use Bun for TypeScript commands and tests.
- Keep target identity in `~/.config/facetime-bridge/config.json` only.
- Never commit local configuration, credentials, recordings, logs, device identifiers, or personal data.
- Keep FaceTime control semantic and fail closed. Do not add coordinate clicks.
- Keep audio provider-neutral. Do not add a bundled provider, token path, or hosted dependency.
- Preserve the one-session audio lock and verified teardown.
