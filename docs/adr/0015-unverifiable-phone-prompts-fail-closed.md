# ADR-0015: Unverifiable Phone prompts fail closed

Status: Accepted

## Decision

An outgoing Phone prompt that does not expose the configured identity and a working semantic action is unavailable behavior. The bridge reports a named failure immediately. It does not infer the target from timing, synthesize keyboard or pointer input, capture the screen, or use Apple-private call entitlements.

## Context

macOS 26.5 can represent a `facetime-audio://` confirmation as two `AXFunctionRowTopLevelElement` proxies under `com.apple.mobilephone`. Their buttons expose only `communication audio` and `Cancel`. The visible target is absent from the Accessibility tree, and `AXPress` can return success without changing the prompt.

## Enforcement

Exact bundle, role, action, and label classification; `PREEXISTING_PHONE_PROMPT`, `AMBIGUOUS_PHONE_PROMPT`, and `UNVERIFIABLE_PHONE_PROMPT`; native regression fixtures; no coordinate or private-entitlement fallback.
