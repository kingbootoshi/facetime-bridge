# ADR-0004: Failure is explicit

Status: Accepted

## Decision

Unavailable permissions, devices, identity, or UI state return named failures. Unknown and idle are distinct. A timeout never becomes success.

## Enforcement

Non-zero command status and structured error codes.
