# ADR-0010: Checks are not suppressed inline

Status: Accepted

## Decision

Source files do not carry inline check suppressions. Exceptions must be visible in repository-level configuration and justified by a contract test.

## Enforcement

Repository scan and CI checks.
