# Fleet operations: implemented contract

This implements the accepted decisions in the coordinator's October 2026
fleet design and implementation assignment. Runtime ownership remains
local and symmetric; the source CLI orchestrates managed transport. There is no
fleet hub and no destination provider credential requirement.

The implemented surfaces are:

- `exec`: runtime-owned pipe execution with byte-preserving streams, destination
  administration ownership, stable results, cancellation and bounded retention.
- `repository prepare`: source-mediated committed-history transfer, recorded clone
  discovery, staged atomic publication and reuse, also automatic during dispatch.
- `project setup`: explicitly authorized committed argv recipes, observable as
  executions, gating task launch without claiming Git prepares dependencies.
- `file put/get`: bounded artifact transport through raw streams.
- Existing worktree/agent operations: task launch, observation, commit fetch and
  safe cleanup. Codex runs with `--no-daemon` in the documented coordinator flow.
- Imported machine-setup login lifecycle fix: stale records are dropped safely,
  exited login commands are reported once, and other providers continue.

See [execution](../flows/execution.md), [repository preparation](../flows/repository-preparation.md),
[worktree dispatch](../flows/worktree-dispatch.md) and the shipped coordinator
skill for syntax, ownership proof, bounds and the end-to-end workflow.

Explicit limits of this implementation: execution results last for one runtime
lifetime; stdin cannot be handed to a new client; output keeps a bounded tail;
shallow/partial clones, submodules and LFS are refused; setup needs an explicit
recipe and authorization; credentials and package logins remain destination-local.
Terminal execution stays on the existing explicit workspace/worktree PTY surface.
None of these limitations silently falls back to provider access or ad hoc SSH.

[Verification and coordinator skill instructions](fleet-operations-verification.md)
record the isolated checks and the graphical-build toolchain limitation.
