# ADR-0007: Runtime configuration is deterministic

Status: Accepted

## Decision

Caller authority enters through `FACETIME_BRIDGE_AUTHORIZED_CALLER_E164` only. The value is one exact E.164 phone number, supplied independently to every bridge process. Browser device selection uses fixed labels and format constraints.

## Enforcement

Strict environment loading rejects missing, malformed, non-E.164, and alternate identity inputs.
