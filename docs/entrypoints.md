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
| Request correlation | `model.RequestLifecycle.nextId` and `AttachedClient.sendRuntimeRequest` or owned-payload send methods | `Tracker.take` consumes once; rejected delivery removes its own registration |
| Pane frames and closure | `AttachedClient.applyPaneFrame`, `requestPaneClose`, `applyPaneExit` | Private frame application owns ACK ordering and recovery; retirement releases pane resources even for repeated exits |
| Tab / workspace changes | `AttachedClient.selectTab` and private tab operations | `AttachedClient` owns tab creation, rename, move, close and tab/workspace snapshot completion; request identity is consumed once |
| Workspace switch / creation | `AttachedClient.selectWorkspace`, `requestWorkspace`, `requestWorkspacePane`, `requestWorkspaceCreation` | `pane_opened` → private arrival or replacement → resource activation; `request_failed` → private bounded fallback |
| Keyboard, mouse, paste and prompts | `AttachedClient.routeKeyInput`, `sendPaneInput`, `inputPaneMouse`, `startPanePaste`, `inputPrompt` | Private methods own leases, paste targets, viewport effects and prompt submission; reusable policy and encoders receive values or model state |
| Directory completion | `AttachedClient.inputPrompt` → private `refreshPathCompletion`; host completion → `completePathCompletion` | One listing at a time; newer queries replace queued work and obsolete results are released |
| Links and editor reuse | `AttachedClient.openLink`, `openMessageFile` | Host `link_opened` → `completeLinkOpening`; runtime `editor_opened` → private `completeEditorOpen`, validating the originating attachment before focus or split |
| Configuration / Lua / plugins / clipboard | `AttachedClient.completeConfigReload`, `completePluginAction`, `completeClipboardCapture`; `executeAction` dispatches private starts | The client transfers ownership, validates generation or execution identity, applies effects and publishes failures; workers remain asynchronous |
| Agent state and history | [`AttachedClient`](../src/client/AttachedClient.zig), [`Model`](../src/model/state/Model.zig), [`agent_reading`](../src/client/application/agents/agent_reading.zig) | `AttachedClient` owns prompt and history request lifecycles; `Model` applies thread snapshots and composer changes; bounded `agent_reading` algorithms receive the model directly |
| Metadata, metrics, suggestions and history output | `handleServerMessage` calls the model or its owned state directly | No forwarding operation receives the whole client |
| Copy mode and history browser | `AttachedClient.applyCopyMode`, `queryHistory`, `applyHistoryResults`, `completeHistoryPrune` | Algorithms retain model dependencies; the client owns host and transport effects |
| Notifications and sounds | `AttachedClient.publishNotification`, `completeNotificationTick`, `applyAgentSound`, `completeAgentSound` | Model, scheduler and playback state retain their own APIs; host completions return to the client |
| Graphics replies | `AttachedClient.applyPaneGraphics` | `pane_graphics.applyResources` receives only retained graphics; recovery requests remain in the client |
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

## Reading the shared owner

`AttachedClient.zig` lists state and imports first, then public adapter operations,
then private implementation. A private method owns the continuation of an
operation. The input, prompt, reload, plugin and clipboard flows use local values
instead of temporary contexts containing a pointer back to the client.
For example, configuration completion resolves the worker result, adopts resources,
delivers the committed layout, publishes its outcome and rearms the watcher.

Shared helpers retain concrete inputs: layout serialization takes `Model` and
caller buffers, mouse encoding takes a report, configuration queries take a
snapshot and writer, and Lua batch validation takes a registry and diagnostic.
These helpers do not receive `AttachedClient`. Test bodies stay in separate files.

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

## Shared values

[`model`](../src/model/README.md) exposes shared value definitions through
[`model.zig`](../src/model/model.zig). Operations still start at the process
owner; the module supplies their data contracts and bounded state, not another
dispatch layer.
