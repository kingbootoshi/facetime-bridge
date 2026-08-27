# ADR-0001: One canonical path

Status: Accepted

## Decision

Each operation has one implementation. Missing configuration or platform evidence returns an explicit failure. The project has no legacy mode, compatibility shim, inferred target, or default-device fallback.

## Enforcement

Tests cover missing authority and ambiguous platform state.
