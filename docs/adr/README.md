# Architecture decisions

These records define the repository's engineering rules. They contain no source-project history or private operational context.

| ADR | Rule |
|---|---|
| [0001](0001-one-canonical-path.md) | One canonical path |
| [0002](0002-untrusted-content-boundary.md) | Untrusted input remains data |
| [0003](0003-evidence-before-verdict.md) | Evidence before verdict |
| [0004](0004-failure-is-never-a-result.md) | Failure is explicit |
| [0005](0005-declared-failure-direction.md) | Gates declare failure direction |
| [0006](0006-one-ai-facade-strict-structured-output.md) | Optional providers stay outside core |
| [0007](0007-prompts-deterministic-conversation-append-only.md) | Runtime configuration is deterministic |
| [0008](0008-durable-truth-vs-coordination.md) | Durable state and process coordination differ |
| [0009](0009-one-owner-per-concept.md) | One owner per concept |
| [0010](0010-the-linter-is-unbypassable.md) | Checks are not suppressed inline |
| [0011](0011-tests-prove-contracts-through-real-seams.md) | Tests prove observable contracts |
| [0012](0012-probe-workbench-dogfood.md) | Probe real platform seams |
| [0013](0013-one-ingress-envelope.md) | One active audio bridge |
| [0014](0014-data-authority-is-structural.md) | One call-card owns identity, action, and state |
| [0015](0015-semantic-control-lifecycle.md) | Mutating controls are semantic lifecycle contracts |
| [0016](0016-setup-does-not-install-system-packages.md) | Setup does not install system packages |
