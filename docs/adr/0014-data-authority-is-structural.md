# ADR-0014: One call-card owns identity, action, and state

Status: Accepted

## Decision

The smallest stable FaceTime call-card container is the authority boundary. One container owns its identity evidence, semantic actions, and call state.

Only the exact configured E.164 number or email from a field proven by a real Accessibility fixture can authorize the container. The display name can corroborate and explain a match, but it never grants authority.

Evidence never crosses call cards, notifications, application surfaces, or processes. Missing, conflicting, or multiple matching containers fail closed.

## Enforcement

The native scanner preserves Accessibility containment. Action candidates and state evidence carry their authorized container. Fixture tests reject display-name-only, cross-container, cross-surface, missing, conflicting, and ambiguous evidence.
