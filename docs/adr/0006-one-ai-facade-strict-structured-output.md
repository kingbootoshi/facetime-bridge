# ADR-0006: Optional providers stay outside core

Status: Accepted (amended 2026-08-29: daemon gRPC surface named as a neutral seam)

## Decision

The repository contains no bundled speech, model, provider, token, or hosted-service client. Integrations plug in through one of two provider-neutral seams: the browser workbench's incoming/outgoing MediaStream pair, or the daemon's `facetimebridge.v1` gRPC surface (raw PCM both directions). The bundled TypeScript adapter (`src/bridge.ts`) is a client for the repo's own daemon, not a provider integration; external stacks (e.g. Pipecat) consume the proto directly and stay outside this tree.

## Enforcement

Runtime source scans and public API review.
