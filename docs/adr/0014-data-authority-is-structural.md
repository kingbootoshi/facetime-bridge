# ADR-0014: One call-card owns identity, action, and state

Status: Accepted

## Decision

The smallest stable FaceTime call-card container is the authority boundary. One container owns its identity evidence, semantic actions, and call state.

Only the exact configured E.164 number, or its full digit-normalized representation, can authorize the container. Contact labels, email addresses, and national-number suffixes are never authority.

Evidence never crosses call cards, notifications, application surfaces, or processes. Missing, conflicting, or multiple matching containers fail closed.

## Enforcement

The native scanner preserves Accessibility containment. Action candidates and state evidence carry their authorized container. Fixture tests reject display-label-only, partial-number, cross-container, cross-surface, missing, conflicting, and ambiguous evidence.
