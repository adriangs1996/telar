# Follow an operation

Start at the event consumer for the process you are changing. Its switch names
the operation. Follow that concrete function to state mutation, runtime request
or host boundary. A reply starts another turn: follow its message name and
request identity. The ownership map is [capabilities.md](capabilities.md);
[ADR 0016](adr/0016-follow-operations-from-process-entrypoints.md) records the decision.

## Process entrypoints

| Process | Start | Update | Input | Drawing / delivery |
| --- | --- | --- | --- | --- |
| GUI | [`GuiClient.start`](../src/gui/GuiClient.zig) | `GuiClient.update` → `dispatch` in the same file | `acceptInput` owns incoming bytes; `.input_ready` → `inputReady` → [`NativeInput.drain`](../src/gui/NativeInput.zig) | `prepare`; `.presented` → `complete` |
| TUI | [`run`](../src/frontend/client/run.zig) | [`events.update`](../src/frontend/client/entrypoints/events.zig) → `dispatch` in the same file | `.input` → [`host_inputs.handleOwnedRead`](../src/frontend/client/controllers/input/host_inputs.zig) | [`presentation_lifecycle`](../src/frontend/client/presentation/presentation_lifecycle.zig) observes changes, prepares drawing, and consumes write completion |
| Runtime | [`Runtime.init` / `run`](../src/backend/runtime/Runtime.zig) | `Runtime.update`: exhaustive event switch | `.client_message` → client read admission → [`requests.dispatch`](../src/backend/runtime/application/requests.zig) | PTY/VT changes publish bounded cell frames; the runtime owns no window |

There are two processes and one state owner per client connection. The GUI and
TUI are host alternatives, not additional runtime authorities. `AttachedClient`
contains the shared client state; adapters embed it and own their rendering and
OS resources. The runtime survives their exit.

## Operation map

| Trigger | Behavior entry | Reply or completion |
| --- | --- | --- |
| Configured action | [`action_routing.apply`](../src/client/operations/input/action_routing.zig) selects native, Lua or plugin; [`actions.apply`](../src/client/operations/input/actions.zig) enumerates native actions | Plugin/worker completion enters the process event switch with its identity |
| Split pane | `actions.apply(.split_pane)` → [`pane_splits.request`](../src/client/operations/panes/pane_splits.zig) | `pane_opened` → `pane_openings.apply` → `pane_splits.confirm`; failure → `request_failures.apply` → `pane_splits.recover` |
| Runtime reply | [`runtime_io.handleRead`](../src/client/entrypoints/runtime_io.zig) → [`server_messages.handleServerMessage`](../src/client/entrypoints/server_messages.zig) | The exhaustive switch calls concrete operations; receive storage remains borrowed only during dispatch |
| Host capabilities / size | [`host_resources`](../src/client/operations/host/host_resources.zig) | Model commit, graphics, geometry and host delivery order are in that module |
| Pane focus, geometry, frame, attachment or closure | [`operations/panes`](../src/client/operations/panes/) | Each operation groups request, confirmation and recovery where applicable |
| Tab / workspace changes | [`operations/tabs`](../src/client/operations/tabs/), [`operations/workspaces`](../src/client/operations/workspaces/) | Wire responses are cases in `server_messages`; request identity is consumed once |
| Keyboard, mouse, paste, prompts and links | [`operations/input`](../src/client/operations/input/) | Direct policy over the client model and actual host/transport ports |
| Configuration / Lua / plugins / clipboard | [`operations/configuration`](../src/client/operations/configuration/), [`operations/host`](../src/client/operations/host/) | VM, OS and worker completions keep their existing lifetime and generation boundaries |
| Agent state and history | [`operations/agents`](../src/client/operations/agents/) | Snapshot, sound, prompt and history messages call the corresponding operation; bounded reading-window algorithms receive the model directly |
| Change review | [`change_review`](../src/client/operations/change_review/change_review.zig) | Open/query/command/application validate pane, attachment, session, edition and request identity together |
| Presentation completion | GUI `complete` or TUI `presentation_lifecycle` → [`presentation_delivery.apply`](../src/client/operations/session/presentation_delivery.zig) | Commit captured generations, flush graphics credits, then let the host request remaining media |
| Runtime request | [`requests.dispatch`](../src/backend/runtime/application/requests.zig) | Calls [`operations`](../src/backend/runtime/application/operations/): panes, tabs, workspaces, graphics, clients, agents, history, reviews, notifications and editors |
| PTY, agent, history, proxy, metrics or persistence completion | `Runtime.update` | Each event names its owner; actual workers remain asynchronous and bounded |

## Example: horizontal split

```text
GUI input / TUI binding
  → actions.apply(.split_pane = .horizontal)
  → pane_splits.request
      plan size; retain request identity; enqueue create_pane

runtime socket completion
  → Runtime.update(.client_message)
  → requests.dispatch(.create_pane)
  → operations/panes.routeCreatePane
      validate; launch and commit pane; attach; reply pane_opened

client socket completion
  → server_messages.handleServerMessage(.pane_opened)
  → pane_openings.apply
  → pane_splits.confirm
      validate correlation; commit layout; offer geometry and resources

next presentation
  → prepare / draw
  → delivery completion retires only captured damage
```

These are successive event turns, not one synchronous stack. Follow `.create_pane`
and `.pane_opened` across the wire. No internal executor or callback registry
selects the split implementation.

## Boundaries that remain

- GUI/TUI host ports implement genuinely different drawing, clipboard, input,
  graphics and OS services.
- Socket and actor workers own asynchronous borrows until completion. Their
  callbacks cannot be replaced with synchronous calls without changing lifetime.
- Model and capability algorithms retain cohesive state invariants. An operation
  may call a bounded queue, layout algorithm, decoder or resource owner directly.
- Interactive, media and observation budgets, quotas, rollback and canonical
  runtime authority remain requirements.

`operations` replaces the former client `controllers` directory after removing
its internal handler/effects assemblies. Domain values and algorithms remain in
`application` where already located; that directory is not a mandatory dispatch
stage. No SoA conversion or performance claim is part of this refactor.

Validation and test migration are recorded in
[global-direct-operations](validation/global-direct-operations/README.md).
