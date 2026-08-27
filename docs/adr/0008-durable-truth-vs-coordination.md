# ADR-0008: Durable state and process coordination differ

Status: Accepted

## Decision

Target configuration is durable local state. Process locks and browser Web Locks coordinate active work only. Coordination locks never become identity authority.

## Enforcement

Secure config ownership checks and independent singleton tests.
