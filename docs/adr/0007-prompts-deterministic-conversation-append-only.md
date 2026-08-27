# ADR-0007: Runtime configuration is deterministic

Status: Accepted

## Decision

The secure local JSON file is the only target authority. The native helper receives an exact target snapshot through argv. Browser device selection uses explicit labels and format constraints.

## Enforcement

Strict config schema and unknown-key rejection.
