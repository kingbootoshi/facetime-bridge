# ADR-0015: Mutating controls are semantic lifecycle contracts

Status: Accepted

## Decision

Every mutating control command maps to one verified semantic Accessibility action inside one authorized call-card container. This applies to `call`, `answer`, and `hangup`; `probe` remains read-only.

A successful command confirms its expected state transition. Coordinate clicks, Phone process termination, surface-wide authorization, and advertised commands that can only return disabled are prohibited.

`hangup` remains part of the public contract. It presses one semantic hangup action for one authorized connected call and confirms ended or idle state. If the supported macOS UI does not expose that action, release is blocked.

## Enforcement

The CLI contract test requires a real success path for each advertised mutating command. Captured lifecycle fixtures prove candidate selection and ambiguity rejection. A live macOS smoke check proves each action and confirmed transition before release.
