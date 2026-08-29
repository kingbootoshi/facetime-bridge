# ADR-0016: Setup does not install system packages

Status: Accepted

## Decision

`facetime-bridge setup` builds and installs the `native/` Swift package executable but never installs or removes system audio packages. BlackHole 2ch and 16ch must already be installed through the architecture-specific Homebrew executable.

Setup verifies the exact cask tokens and `homebrew/cask` tap with Homebrew auto-update disabled. Homebrew remains the authority for cask checksums and artifacts; the bridge does not duplicate vendor homepage or download URL policy.

Missing prerequisites stop setup before it writes bridge state and return the exact manual install command for only the missing casks. Caller authority is never prompted for or persisted; setup requires the canonical E.164 environment variable before mutation.

## Enforcement

Setup tests cover fixed Homebrew paths, the SwiftPM release product, official tap and token validation, missing-package errors, replacement-cask rejection, and strict environment authority. Real setup dogfood reaches the package build without installing or updating system packages.
