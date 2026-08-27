# ADR-0013: One active audio bridge

Status: Accepted

## Decision

One browser profile can hold one FaceTime audio bridge. A second bridge request fails before opening devices. Teardown releases every track, sink, processor, and lock.

## Enforcement

Two-to-one-to-zero lifecycle smoke test.
