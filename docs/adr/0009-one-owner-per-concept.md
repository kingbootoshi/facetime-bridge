# ADR-0009: One owner per concept

Status: Accepted

## Decision

The process environment owns caller injection. The TypeScript and Swift boundaries independently validate the same canonical variable before control. The Swift helper owns macOS Accessibility control. The browser module owns audio device selection and conversion.

## Enforcement

Module boundaries, strict E.164 loader tests, and review.
