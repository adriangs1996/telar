---
status: superseded by ADR-0014
---

# Agent mode is a client projection of one runtime

Superseded on 2026-09-11: there is no second composition. A thread is shown
as the surface of its own pane inside the workbench, see
[ADR 0014](0014-native-chrome-is-a-second-presentation-adapter.md). The
invariant that a live thread is always a pane, and that provider knowledge
lives in manifests and readers, stands.

Supervising many agents needs a view organized by project and attention,
not by workspace, tab and pane. The obvious way to build it is a second
runtime model of "threads" with its own topology. We decided against that.

## Decision

Agent mode is a second composition of the same client over the same runtime.
The mode, the focus state (browse or interact), the selected thread and the
view tab are disposable client state carried in `update_client_layout` like
sidebar visibility. The runtime never learns which mode a client is in. A
live thread is always a pane in a tab in a workspace; agent mode indexes
those panes by project and attention instead of creating a second topology.
Opening a thread whose pane lives in another workspace uses the existing
agent navigation flow, including the workspace handoff and the bookmark that
restores the multiplexer layout on the way back.

Nothing in the client names a provider. Provider knowledge lives only in the
agent manifests (recognition, launch argv, options, live commands), the
per-provider session readers keyed by transcript kind, and the hook
installers.

## Considered options

- A runtime-owned thread topology (a "thread" as a first-class runtime
  object with its own panes) would have duplicated workspace, tab and pane
  lifecycle and forced every existing flow to learn a second parent.
- Attaching panes across workspaces without a handoff would keep the
  multiplexer's active workspace untouched, at the cost of a new runtime
  attachment and geometry-lease rule. It stays possible later; the review
  chose the handoff for the first version.

## Consequences

- Toggling the mode is free: composition changes, runtime state does not.
- The thread registry (ADR 0010) is mode-independent data the multiplexer
  sidebar can also use for badges and the goto picker.
- Adding a provider is manifest data plus, at most, a session reader.
