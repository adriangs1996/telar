# Agent navigation

The sidebar identifies an agent by pane and generation. Navigation resolves
that exact identity against the current client model before it changes focus
or asks the runtime for another workspace.

## Flow

```text
sidebar hit region
       |
View.handleMouse -> AgentKey
       |
InputHandler.mouse
       |
AttachedClient.navigateAgent
       |
ClientModel.planAgentNavigation
       |
       +-- local tab -> AttachedClient.selectTab -> AttachedClient.applyPaneFocus
       |
       +-- remote pane -> AttachedClient.requestWorkspacePane
```

The operation owns the branch and local ordering. A pane in an
inactive local tab selects that tab before focus. If tab selection is blocked
by a pending canonical snapshot, focus does not run against the old active
tab. A pane outside the projected workspace requests a handoff only when no
runtime response is pending.

The model rejects a missing agent or a stale pane generation before any
effect. Worktree agents carry no ordinary-workspace fallback. If the remembered
remote pane vanished, only agents from an ordinary workspace can use the
handoff flow's workspace retry.

The operation does not draw. Local selection and focus commit their own
`ClientModel.Version` dimensions through existing operations. A remote handoff
commits the normal empty workspace transition after its protocol messages enter
the outbox. `Presenter` observes either result at the event boundary.

## Fullscreen across workspaces

Leaving a workspace retains every reconciled tab layout in the client model,
including inactive tabs. The workspace bookmark still chooses the default tab
and pane for ordinary workspace selection; it does not determine which tab
layout a sidebar agent receives.

On a sidebar return, the confirmed `(workspace, tab)` identity selects the
retained tree. Its fullscreen flag, split axes and ratios survive. The clicked
pane remains the focus even when another pane was focused in the saved tree.
Canonical pane reconciliation validates membership before applying the tree
and consumes only that tab's cache entry. Other tabs remain available for later
selection. See [Client layout persistence](client-layout-persistence.md).

## Validation

- `src/model/state/Model.zig` resolves exact generations and local or
  remote plans without exposing the agent replica.
- `src/client/AttachedClient.zig` applies selection before
  focus and calls the concrete tab, focus and handoff operations.
- `src/frontend/client/tests/notifications_and_agents.zig` and
  `src/frontend/client/tests/synchronization.zig` exercise stale/pending
  suppression and navigation order on the real client.
- `src/frontend/client/tests/synchronization.zig` proves local fullscreen focus,
  direct pane handoff and a workspace round trip into a previously inactive
  fullscreen tab through the substituted runtime socket. The requested pane
  differs from saved focus, and canonical pane order differs from split order.
