# ADR-0005: Gates declare failure direction

Status: Accepted

## Decision

Calling, answering, and hanging up fail closed when identity or state is uncertain. Audio opening fails closed when an exact device, format, or singleton lock is unavailable.

## Enforcement

Negative contract tests and real platform smoke checks.
