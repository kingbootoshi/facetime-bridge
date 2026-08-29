# ADR-0005: Gates declare failure direction

Status: Accepted

## Decision

Calling, answering, and hanging up fail closed when their call-card identity, semantic action, or state is missing, conflicting, or ambiguous. A false positive can act on the wrong call; a false negative only blocks automation.

Audio opening fails closed when an exact device, format, or singleton lock is unavailable. Unavailable real Accessibility evidence blocks release instead of enabling broader matching.

## Enforcement

Negative contract tests cover zero and multiple containers, actions, and states. Real platform smoke checks confirm that no action occurs under uncertainty.
