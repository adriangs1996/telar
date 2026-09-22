# Follow an operation

Start at the event consumer for the process you are changing. Its switch names
the operation. Follow that concrete function to state mutation, runtime request
or host boundary. A reply starts another turn: follow its message name and
request identity. The ownership map is [capabilities.md](capabilities.md);
[ADR 0016](adr/0016-follow-operations-from-process-entrypoints.md) records the decision.

## Process entrypoints

| Process | Start | Update | Input | Drawing / delivery |
| --- | --- | --- | --- | --- |
| GUI | [`GuiClient.run` → `windowReady`](../src/gui/GuiClient.zig) | `GuiClient.update` → `dispatch` in the same file | `acceptInput` owns incoming bytes; `.input_ready` → `inputReady` → [`GuiClient.drainInput`](../src/gui/GuiClient.zig) | `draw` → private `prepare`; `.presented` → `complete` |
| TUI | [`run`](../src/frontend/client/run.zig) | [`events.update`](../src/frontend/client/entrypoints/events.zig) → `dispatch` in the same file | `.input` → [`host_inputs.handleOwnedRead`](../src/frontend/client/controllers/input/host_inputs.zig) | [`presentation_lifecycle`](../src/frontend/client/presentation/presentation_lifecycle.zig) observes changes, prepares drawing, and consumes write completion |
| Runtime | [`Runtime.init` / `run`](../src/backend/runtime/Runtime.zig) | `Runtime.update`: exhaustive event switch | `.client_message` → client read admission → [`requests.dispatch`](../src/backend/runtime/application/requests.zig) | PTY/VT changes publish bounded cell frames; the runtime owns no window |

There are two processes and one state owner per client connection. The GUI and
TUI are host alternatives, not additional runtime authorities. `AttachedClient`
contains the shared client state; adapters embed it and own their rendering and
OS resources. The runtime survives their exit.

Keyboard routing has an explicit result boundary: `GenericRouter.routeEvent`
returns `Decision` data. `GuiClient.applyInputDecision` and `host_inputs.applyDecision`
execute it with an exhaustive switch, then route the next event against current
state. See [Key routing](flows/key-routing.md) and the full
[split trace](flows/pane-split.md).

## Operation map

Startup activates socket tasks through `AttachedClient.startRuntimeIo` in the
GUI and `startRuntimeRead` before host negotiation in the TUI. `AttachedClient.scheduleConfigReload`
and `synchronizeBars` select the live configuration; reload workers and bar timers
receive only their own state and concrete dependencies. Native transport and timer
ports bind to `NativeLoop`, and the configuration watcher binds to `ConfigurationReload`.

| Trigger | Behavior entry | Reply or completion |
| --- | --- | --- |
| Configured action | [`AttachedClient.executeAction`](../src/client/AttachedClient.zig) applies binding/effect authority and dispatches native, Lua or plugin actions | Plugin/worker completion enters the process event switch with its identity |
| Split pane | `AttachedClient.executeAction(.split_pane)` → [`AttachedClient.requestPaneSplit`](../src/client/AttachedClient.zig) | `pane_opened` → `AttachedClient.completePaneOpen` → `AttachedClient.confirmPaneSplit`; failure → `AttachedClient.failRuntimeRequest` → `AttachedClient.recoverPaneSplit` |
| Routed API command | `handleServerMessage(.client_command)` → private `completeClientCommand` → `executeClientCommand` | Returns `complete_client_command` with the original route, request ID and action; errors become `.failed` |
| Runtime reply | [`AttachedClient.receiveRuntime`](../src/client/AttachedClient.zig) → [`AttachedClient.handleServerMessage`](../src/client/AttachedClient.zig) | The exhaustive switch calls concrete operations; receive storage remains borrowed only during dispatch |
| Host capabilities / size | [`host_resources`](../src/client/AttachedClient.zig) | Model commit, graphics, geometry and host delivery order are in that module |
| Pane focus and geometry delivery | `AttachedClient.deliverPaneFocus`, `resizePane`, `togglePaneFullscreen` | Private geometry delivery validates the committed revision before host effects |
| Pane attachment | `AttachedClient.attachVisiblePanes` | `pane_opened` → private `confirmPaneAttachment`; failure → private `recoverPaneAttachment` |
| Request correlation | `LifecycleState.nextId` and `AttachedClient.sendRuntimeRequest` or owned-payload send methods | `Tracker.take` consumes once; rejected delivery removes its own registration |
| Pane frames and closure | [`operations/panes`](../src/client/operations/panes/) | Frame application and pane closure retain their existing operations |
| Tab / workspace changes | [`AttachedClient`](../src/client/AttachedClient.zig), remaining selection/move/handoff operations | `AttachedClient` owns tab creation, rename, close and tab/workspace snapshot completion; request identity is consumed once |
| Keyboard, mouse, paste and prompts | [`operations/input`](../src/client/operations/input/) | Direct policy over the client model and actual host/transport ports |
| Links and editor reuse | `AttachedClient.openLink`, `openMessageFile` | Host `link_opened` → `completeLinkOpening`; runtime `editor_opened` → private `completeEditorOpen`, validating the originating attachment before focus or split |
| Configuration / Lua / plugins / clipboard | [`operations/configuration`](../src/client/operations/configuration/), [`operations/host`](../src/client/operations/host/) | VM, OS and worker completions keep their existing lifetime and generation boundaries |
| Agent state and history | [`AttachedClient`](../src/client/AttachedClient.zig), [`Model`](../src/client/model/Model.zig), [`agent_reading`](../src/client/application/agents/agent_reading.zig) | `AttachedClient` owns prompt and history request lifecycles; `Model` applies thread snapshots and composer changes; bounded `agent_reading` algorithms receive the model directly |
| Change review | [`AttachedClient`](../src/client/AttachedClient.zig) | Open/query/command/application validate pane, attachment, session, edition and request identity together |
| Presentation completion | GUI `complete` or TUI `presentation_lifecycle` → [`presentation_delivery.apply`](../src/client/operations/session/presentation_delivery.zig) | Commit captured generations, flush graphics credits, then let the host request remaining media |
| Runtime request | [`requests.dispatch`](../src/backend/runtime/application/requests.zig) | Calls [`operations`](../src/backend/runtime/application/operations/): panes, tabs, workspaces, graphics, clients, agents, history, reviews, notifications and editors |
| PTY, agent, history, proxy, metrics or persistence completion | `Runtime.update` | Each event names its owner; actual workers remain asynchronous and bounded |

## Example: horizontal split

```text
GUI input / TUI binding
  → AttachedClient.executeAction(.split_pane = .horizontal)
  → AttachedClient.requestPaneSplit
      plan size; retain request identity; enqueue create_pane

runtime socket completion
  → Runtime.update(.client_message)
  → requests.dispatch(.create_pane)
  → operations/panes.routeCreatePane
      validate; launch and commit pane; attach; reply pane_opened

client socket completion
  → AttachedClient.handleServerMessage(.pane_opened)
  → AttachedClient.completePaneOpen
  → AttachedClient.confirmPaneSplit
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
