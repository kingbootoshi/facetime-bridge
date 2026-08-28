# ADR-0012: Probe real platform seams

Status: Accepted

## Decision

Capture the real Accessibility hierarchy before changing identity, action, or state selectors. Redact personal values without changing roles, attributes, actions, or containment.

Validate Accessibility surfaces and audio devices before action. Verify every mutating control command and audio path on the real supported macOS surface before release. A changed UI hierarchy becomes unavailable until its fixture and classifier are updated.

## Enforcement

The fixture capture tool, doctor output, probe command, browser workbench, full-lifecycle fixtures, and release smoke checklist.
