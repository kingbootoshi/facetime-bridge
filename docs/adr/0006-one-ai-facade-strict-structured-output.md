# ADR-0006: Optional providers stay outside core

Status: Accepted

## Decision

The repository contains no bundled speech, model, provider, token, or hosted-service client. Integrations consume the provider-neutral incoming MediaStream and return an outgoing MediaStream.

## Enforcement

Runtime source scans and public API review.
