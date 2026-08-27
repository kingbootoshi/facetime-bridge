# ADR-0002: Untrusted input remains data

Status: Accepted

## Decision

Accessibility text, local configuration, browser device labels, and child-process output are untrusted data. Validate their shape and limits before use. Never execute text collected from a platform surface.

## Enforcement

Strict parsers, argv-only process execution, byte limits, and semantic allowlists.
