# ADR-0011: Tests prove observable contracts

Status: Accepted

## Decision

Tests verify config ownership, strict native output, bounded processes, CLI parsing, device format, singleton behavior, and teardown. Synthetic Accessibility nodes test edge cases but never establish the real UI contract.

Redacted captures from the supported macOS FaceTime lifecycle are the authoritative fixtures for outgoing, incoming, dialing, connected, ended, ambiguous, and hangup behavior.

## Enforcement

Bun tests compile the Swift classifier against captured fixtures. Live macOS smoke checks exercise each mutating control command before release.
