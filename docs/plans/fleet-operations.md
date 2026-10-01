# Fleet operations

Status: draft design, started with Adrian on 2026-10-01. Coordinator-mediated
Git transfer, an administration workspace as the default command context, and
separate stdin/stdout/stderr with an optional terminal are decided. Repository
storage, execution lifecycle details and project setup still need review. No
implementation is assigned by this document.

This extends [Machines](machines.md), rather than introducing a fleet hub.
Any machine can dispatch to another. Each runtime owns only its own work;
the dispatching CLI orchestrates transfers.

## Problem and current behavior

Dispatch currently requires the destination clone to exist. When it does not,
the coordinator must arrange it outside the worktree flow. Closing a workspace
also makes an existing clone undiscoverable unless its path is supplied.

General command execution has partial building blocks but no complete CLI
contract independent of a worktree:

- `workspace create -- COMMAND` already starts an arbitrary command without a
  repository: [workspace.zig](../../src/cli/workspace.zig), `run`.
- `worktree exec --wait -- COMMAND` already launches, waits and returns the
  command's exit status and final terminal text:
  [worktree.zig](../../src/cli/worktree.zig), `exec` and `waitForExit`.
- `--machine LABEL` forwards Telar commands and preserves argument boundaries:
  [Machine dispatch](../flows/machine-dispatch.md).
- Repository resolution searches open runtime workspaces or the explicitly
  named workspace/path: [worktree.zig](../../src/cli/worktree.zig), `resolve`.
- Git transfer already starts on the dispatching machine and uses managed SSH
  with agent forwarding disabled: [Worktree dispatch](../flows/worktree-dispatch.md).

The desired user flow is one Telar dispatch which prepares the destination
project when necessary, starts work, exposes its progress and brings commits
back. Routine fleet operations should not require an external SSH workaround.

## Decided: private repository access

Adrian selected transfer from the coordinator. The destination does not need
provider credentials to receive the Git commits used for a task or send its
result back. The same preparation flow applies to public and private projects.

The dispatching machine may use its own existing provider access to update its
local clone. The destination receives the selected Git data over Telar's
managed SSH connection. Private keys, tokens, credential stores, SSH agent
forwarding and the source clone's credential-bearing configuration are outside
that transfer.

Independent destination access to a Git provider is not needed for this flow.
If added later, it requires a separate explicit setup policy. Existing provider
access on a destination is neither removed nor taken as permission to use it
automatically.

## Repository preparation

Proposed public operation, run in the source clone:

```sh
telar repository prepare --machine LABEL --from HEAD --json
```

`worktree create --machine` calls the same preparation flow before dispatch;
the separate command permits preparing a project ahead of time and inspecting
the result. This is proposed syntax, not an existing command.

Preparation must distinguish these cases:

| Destination state | Result |
| --- | --- |
| One matching usable clone | Reuse it; transfer the selected commit as needed |
| No matching clone | Prepare a new clone in an owned staging directory |
| Multiple matching clones | Require an explicit destination selection |
| Chosen directory contains unrelated content | Fail without overwriting it |
| Previous preparation was interrupted | Resume or remove only owned staging state |

Resolve a project by its repository identity and an explicitly recorded local
path, independently of whether its workspace is currently open. Reuse existing
catalog/persistence mechanisms if they can represent this relationship; do not
add a parallel registry without checking them first. The remote runtime records
only its local project state, not the fleet.

Choose the managed clone root and naming rule explicitly. Paths must remain
unambiguous across providers and organizations, and must not use unchecked URL
components as filesystem paths. Explicit user-owned clones remain usable.

Preparation stages Git data, verifies the requested commit and identity, then
publishes the usable destination atomically. Serialize competing preparations
of the same project. A retry must not create another clone or delete somebody
else's work. Report the resulting path, commit and preparation status.

The exact Git initialization sequence needs a disposable prototype. Reuse the
existing push/fetch transfer instead of copying the source `.git` directory,
SSH configuration or a credential-bearing origin URL. Preserve non-secret
transport details separately from the normalized matching identity.

Only the selected committed history travels by default, as in current worktree
dispatch. Report uncommitted files remaining at the source. Define handling of
shallow/partial clones, submodules and Git LFS before calling a destination
ready; ordinary commit transfer must not silently claim these are complete.

## Project setup

Repository preparation establishes Git state. Project setup establishes the
environment required to work: declared tools, dependencies and any project
setup command. These are separate reported stages, so an installed clone with
a failed dependency setup is not reported as ready for an agent.

Inspect existing project configuration before choosing where setup declarations
live. Avoid framework guesses and automatically executing arbitrary discovered
scripts. A declared project setup recipe runs as observable runtime-owned work
with an explicit working directory, outcome and cancellation path. Its execution
authority must follow the applicable [invariants](../invariants.md).

Credentials required by package registries or project services are a separate
decision. The Git-transfer policy does not authorize copying them. Setup must
report an unresolved dependency rather than inventing a credential transfer.

## General execution

Proposed operation:

```sh
telar --machine LABEL exec [--workspace ID] [--cwd PATH] -- PROGRAM ARGUMENTS...
```

This is proposed syntax. Execution must work without a Git repository or GUI.
Use explicit argv as the default; shell scripts must be explicit invocations,
not an implicit parsing of joined arguments.

Adrian selected an administration workspace owned by the destination as the
default context, with its HOME as the launch directory when no workspace or
directory is supplied. An explicit workspace selects its stable path; `--cwd`
overrides the launch directory without changing workspace identity. Never inherit
a numeric workspace id from another machine or consult a window's focus to
decide a headless operation's target.

Adrian selected separate stdin/stdout/stderr streams as the default execution
mode, with an explicit terminal option for interactive work. Raw streams preserve
bytes and keep stderr separate. Terminal mode owns a PTY and follows terminal
semantics; it cannot promise separate stderr or byte-preserving output. The
terminal flag's spelling remains to be chosen when defining the CLI contract.

An administration workspace is created lazily and reused while it exists. It
must respect current removal semantics when its final pane ends; do not start
a keeper shell merely to preserve it. Results remain addressable independently
of the workspace's lifetime. A user workspace with a similar display name must
not be claimed as an automatically owned workspace.

Define these execution behaviors before implementation:

- Default foreground execution streams output and returns the child's status.
  Explicit detached execution returns an identity for status, output and cancel.
- A disconnected CLI leaves the runtime-owned command valid. A reconnect can
  inspect it; an uncertain launch is not blindly repeated.
- Timeout distinguishes stopping the caller's wait from cancelling the child.
  Cancellation names only the owned execution, not another pane or runtime.
- Both execution modes follow the decided I/O contract. Never reconstruct binary
  output or separate stderr from terminal screen text. Define stdin EOF,
  backpressure and disconnect behavior before exposing raw streams.
- State, output retention and transfer queues have declared bounds. Long-running
  transfer/setup/output work stays outside the interactive path. No renderer or
  request handler performs Git, dependency installation or blocking collection.

Reuse existing launch, ownership, history and command-capture flows where their
contracts fit. If raw execution requires pipe-backed processes, design their
bounded runtime state and resources explicitly in the flat model. Do not build
a second SSH command runner whose processes disappear with the requesting CLI.

## Delivery order and acceptance

1. Complete general execution's lifecycle and bounded I/O contracts around the
   decided defaults; implement it against an isolated runtime with no repository
   and no GUI.
2. Add idempotent repository preparation using source-side Git transfer and
   integrate it into remote worktree creation.
3. Define and add project setup reporting/recipes after inspecting existing
   configuration and resolving dependency credential behavior.
4. Extend the dispatch skill to use the completed Telar operations for remote
   briefs, setup and command execution. No hidden SSH repair path.

End-to-end acceptance includes a private source clone, a destination with no
clone and no Git-provider credentials, interrupted/concurrent preparation,
workspace removal and retry, explicit destination ambiguity, arbitrary commands
outside repositories, argument preservation, bounded output, disconnect and
cancellation. Use local fake SSH and disposable runtimes by default. Live fleet
tests require the specific machine and actions to be authorized.

Task brief/file transfer is another required part of a complete dispatch. Decide
whether dedicated bounded file transfer is needed for the chosen execution I/O;
do not turn terminal text into a byte-preserving file transport.

## Remaining decisions

- Managed clone location and persistence/discovery without open workspaces.
- Stream backpressure, retention and detached lifecycle.
- Project setup declaration, repeatability and dependency credential policy.
- Submodule/LFS/partial-clone readiness and task-file transfer.


## Implemented contract

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
