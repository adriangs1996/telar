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
agent_navigation.apply
       |
NavigateAgentHandler -> ClientModel.planAgentNavigation
       |
       +-- local tab -> SelectTabHandler -> FocusPaneHandler
       |
       +-- remote pane -> RequestWorkspaceHandoffHandler
```

The application handler owns the branch and local ordering. A pane in an
inactive local tab selects that tab before focus. If tab selection is blocked
by a pending canonical snapshot, focus does not run against the old active
tab. A pane outside the projected workspace requests a handoff only when no
runtime response is pending.

The model rejects a missing agent or a stale pane generation before any
effect. Worktree agents carry no ordinary-workspace fallback. If the remembered
remote pane vanished, only agents from an ordinary workspace can use the
handoff flow's workspace retry.

The handler does not draw. Local selection and focus commit their own
`ClientModel.Version` dimensions through existing handlers. A remote handoff
commits the normal empty workspace transition after its protocol messages enter
the outbox. `Presenter` observes either result at the event boundary.

## Proof

- `src/frontend/client/model.zig` proves exact generation lookup and local or
  remote planning without exposing the agent replica.
- `src/frontend/client/application/agent_navigation.zig` proves selection
  before focus, stale and pending suppression, and effect failure ordering.
- `src/frontend/client/agent_navigation.zig` wires the plan to tab, focus and
  handoff adapters.
- `src/frontend/client/client_test.zig` proves local tab focus and remote pane
  handoff through the substituted runtime socket.
