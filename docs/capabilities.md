# Capability map

Telar is organized by process ownership, then by capability. This map locates
state and behavior; the maps in `docs/flows/` trace external events. Directory
locations below are not permission to import every file they contain.

Concrete types and generic families follow [Zig source layout](zig-source-layout.md).
Capabilities expose explicit public files, not mandatory directory barrels.
The package entrypoints are `src/core/core.zig`, `src/backend/backend.zig`,
`src/client/client.zig` and `src/frontend/frontend.zig`. They export canonical
values needed across Zig module boundaries.

For `telar-client`, `src/client/capabilities.json` records:

- `entrypoint`: the package module entrypoint;
- `capabilities`: explicit directory owners, including nested capabilities;
- `public`: files another capability may import;
- `assembly_imports`: additional files the entrypoint imports for test discovery,
  not permission for another capability to depend on private helpers.

Adding a public entry is an API decision. Do not export a fixture or an internal
helper just to silence a boundary error. File separation does not make struct
fields private or transfer mutation authority.

## Shared core

| Capability | Location | Responsibility |
| --- | --- | --- |
| Schema | `src/core/schema/` | Bounded runtime-client messages and their encoding |
| UI values | `src/core/ui/` | Cells, buffers, geometry and shared text values |
| Transport | `src/core/transport/` | Framed byte streams and local endpoint values |
| Lua runtime | `src/lua/` | Vendored C API, metered VM and restricted standard-library sandbox |

Core owns no live runtime or client state and imports neither process package.

## Executable entrypoints

`src/main.zig` collects process arguments and dispatches the parsed command.
`src/cli/parser.zig` owns command values. Files such as `src/cli/server.zig` and
`src/cli/client.zig` prepare their process, choose production dependencies and
invoke the runtime or TUI. Main-build types live in `build/`.

## Runtime capabilities

| Capability | Location | Owns |
| --- | --- | --- |
| Runtime | `src/backend/runtime/Runtime.zig` | Lifecycle of one runtime instance |
| Pane | `src/backend/pane/Pane.zig` | Child, PTY terminal state, cell projection and pane lifecycle |
| PTY | `src/backend/pty/` | Verified launch, PTY I/O and child lifecycle |
| Media | `src/backend/media/` | Bounded child Kitty-graphics ingestion |
| Process | `src/backend/process/` | Native metadata and foreground-process observation |
| Engine | `src/backend/engine/` | Bounded prompts to one headless agent child |
| Agent | `src/backend/agent/` | Evidence precedence and projected agent state |
| History | `src/backend/history/` | Command observation, queries and durable storage |
| Proxy | `src/backend/proxy/` | Network observation and TLS actors |
| Proxy capture | `src/backend/proxy/capture/` | Bounded exchanges, delivery, decoding and pairing |
| Tap plugins | `src/backend/plugins/` | Supervised Lua workers and authorized effects |
| Transport | `src/backend/transport/` | Runtime-side local connection and handshake |

The `examples/plugins/agent-commands` package integrates Proxy capture, Tap
plugins and History. Provider-specific JSON and SSE classification stays in
Lua; the runtime owns bounded exchange delivery, authorization and durable
results.

### Runtime composition

| Part | File or directory | Responsibility |
| --- | --- | --- |
| Runtime | `src/backend/runtime/Runtime.zig` | Acquire, compose, run and tear down |
| Resources | `src/backend/runtime/resources/Resources.zig` | Physical ownership and startup rollback |
| Event loop | `src/backend/runtime/Loop.zig` | Event storage, selection and stop coordination |
| Application | `src/backend/runtime/application/Application.zig` | Client state and cross-capability invariants |
| Model | `src/backend/runtime/application/RuntimeModel.zig` | Authoritative semantic state |
| Pane launcher | `src/backend/runtime/application/GenericPaneLauncher.zig` | Pane creation and actor startup transaction |
| Event sources | `src/backend/runtime/Sources.zig` | Arm infrastructure work |
| Event dispatcher | `src/backend/runtime/application/event_dispatcher/GenericEventDispatcher.zig` | Classify completions and delegate |
| Scheduler | `src/backend/runtime/application/GenericScheduler.zig` | Start bounded asynchronous work |
| Request dispatch | `src/backend/runtime/application/request_dispatch.zig` | Request-scoped controllers and handlers |
| Commands and queries | `src/backend/runtime/application/commands/`, `src/backend/runtime/application/queries/` | Synchronous use cases and reads |
| Coordinators | `src/backend/runtime/application/coordinators/` | Description work and evidence expiry |
| Request entrypoints | `src/backend/runtime/entrypoints/requests/` | Wire translation, errors and responses |
| Event entrypoints | `src/backend/runtime/entrypoints/events/` | Actor and resource completion policy |
| Attachment | `src/backend/runtime/attachment/` | Per-client projection and acknowledgement |
| Client coordination | `src/backend/runtime/client/` | Admission, routing and send completion |
| Delivery | `src/backend/runtime/delivery/` | Response scheduling, encoding and send transactions |
| Lifecycle | `src/backend/runtime/lifecycle/` | Stop authority, signal and ordered teardown |
| Observability | `src/backend/runtime/observability/` | Host metrics and diagnostic telemetry |

High fan-out belongs in composition, actor binding and request dispatch. A leaf
capability needs an indivisible invariant to justify it.

## Shared client capabilities

`telar-client` shares implementation across independent connections. It owns
neither runtime truth nor a common instance of navigation or focus.

| Capability | Location | Owns |
| --- | --- | --- |
| Attached client | `src/client/AttachedClient.zig` | Shared aggregate: model, transport, configuration, plugins, host ports |
| Controllers | `src/client/controllers/` | Slice adapters wiring handlers to the model and host ports |
| Model | `src/client/model/Model.zig` | Disposable semantic state and transitions |
| Application | `src/client/application/` | Command handlers and narrow effect ports |
| Entrypoints | `src/client/entrypoints/runtime_messages.zig` | Synchronous decoded-message dispatch |
| Panes | `src/client/panes/` | Cells, damage, child modes and attachment-aware commits |
| Workspace | `src/client/workspace/` | Tabs, splits, navigation and explicit geometry |
| Input | `src/client/input/` | Semantic values, bindings, leases, editing and child encoding |
| Connection | `src/client/connection/` | Bounded outbox, correlation and transport state |
| Resources | `src/client/resources/` | Clock, timers, configuration reload, layout persistence and telemetry state |
| Presentation | `src/client/presentation/` | Projections, preparation, completion, geometry and title port |
| Graphics | `src/client/graphics/` | Image retention, generations, quotas and credits |
| Attachments | `src/client/attachments/` | Catalog, markers and sensitive-byte lifetime |
| Agents | `src/client/agents/` | Bounded projection of runtime agent state |
| Notifications and bars | `src/client/notifications/`, `src/client/bars/` | Semantic control state |
| Links | `src/client/links/` | Targets, URI rules and pointer ownership |
| Configuration | `src/client/config/` | Typed configuration, client-owned Lua generation and bounded callback values |
| Appearance | `src/client/appearance/` | Named color themes, palette roles and overrides |
| Plugins | `src/client/plugins/` | Registry, protocol and isolated workers |
| Transport | `src/client/transport/` | Client-side local connection and handshake |

## TUI capabilities

| Capability | Location | Owns |
| --- | --- | --- |
| Terminal client | `src/frontend/client/TerminalClient.zig` | Embeds `AttachedClient`, owns terminal resources, binds host ports, runs the select driver |
| Sound | `src/frontend/sound/` | Host-audio queue and platform worker |
| Input | `src/frontend/input/` | Terminal decoder integration with shared routing |
| Workspace | `src/frontend/workspace/` | Cell compositor over the shared workspace model |
| Presentation | `src/frontend/presentation/` | Screen diff, terminal output and pacing |
| Graphics | `src/frontend/graphics/` | Host transfer state, probes and overlays |
| UI | `src/frontend/ui/` | Client-only focus, hits and icons |
| Widgets | `src/frontend/widgets/` | Chrome and interaction surfaces |
| Platform | `src/frontend/platform/` | Host TTY and resize adapters |

Shared handlers receive their model and named ports, never the concrete TUI
aggregate. `presentation_projection` supplies host context and exposes physical
resources separately. `Presenter` owns prepared rendering caches; the shared
lifecycle owns observed, prepared and delivered revisions. Host output retains
sealed bytes and the completion token. None of these file moves changes the
existing event driver or permits cancelling a partially written terminal diff.

## Dependency direction

```text
telar-frontend -> telar-client -> telar-core <- telar-backend
       |                             ^
       +-----------------------------+
```

A native adapter imports `telar-client`. Its only named project dependency is
`telar-core`. Core's Unicode provider uses Ghostty data without constructing a
client VT. Retained media uses guarded POSIX shared memory. The common test
binary links no FreeType, AppKit or GPU framework.

`zig build check-client-boundaries` checks module direction, literal imports,
exact path casing and public capability admission. `test-client` and `check`
include it. Build assertions also reject reverse process-module dependencies.
`zig build codestyle` checks the AST-based source conventions; `test` and `check`
run it without enabling fixes. `check` also includes `check-programs`, which
analyzes executable entrypoints: discovering a program's tests alone does not
analyze its `main` function.

Principal internal edges remain:

```text
frontend/client    -> client behavior and concrete TUI capabilities
client/application -> shared model and narrow effect ports
frontend/input     -> presentation
frontend/workspace -> input, presentation, ui
frontend/widgets   -> agents, workspace, attachments, ui
frontend/graphics  -> workspace, presentation, ui, widgets
client/config      -> appearance, bars, environment, input, layout,
                      notifications
client/plugins     -> config, input
backend/runtime    -> pane, pty, media, process, agent, history, proxy,
                      plugins, transport
backend/pane       -> pty, media, process, history
backend/agent      -> pane, history
```

A new edge needs an ownership or invariant justification. Renaming a directory
or adding an export does not supply one.

## Process entrypoints

The event owners classify completions and delegate. Controllers translate the
protocol; handlers retain ordering, mutation and rescheduling policy.

### Client

`src/frontend/client/run.zig` owns the event driver. Its entrypoint is
`src/frontend/client/entrypoints/events.zig`.

| Event | Entrypoint |
| --- | --- |
| Host bytes and parser/binding deadlines | [`host_inputs`](flows/host-input-to-screen.md) |
| Capability deadline | [`host_capabilities.handleExpiry`](flows/host-capabilities.md) |
| Host resize | [`host_resizes.handle`](flows/host-resize.md) |
| Runtime socket read/write | [`runtime_transport`](flows/runtime-transport.md) |
| Draw, host write and media tick | [`presentation_lifecycle`](flows/presentation-lifecycle.md) |
| Sidebar animation | [`sidebar_animations.handleTick`](flows/sidebar-animation.md) |
| Notification tick | [`notifications.handleTick`](flows/notifications.md) |
| Agent sound completion | [`agent_sounds.handlePlayed`](flows/agent-sound.md) |
| Telemetry tick/write | [`telemetry`](flows/client-telemetry.md) |
| Config reload | [`config_reloads.handle`](flows/config-reload.md) |
| Plugin result | [`plugin_actions.complete`](flows/plugin-action.md) |
| Clipboard image result | [`clipboard_images.complete`](flows/clipboard-image.md) |

### Runtime

`Runtime.run` handles stop completion and delegates other events through the
application dispatcher. Specialized dispatchers handle client, agent, history,
observability and pane events.

| Event | Owner below `src/backend/runtime/` |
| --- | --- |
| Accept / handshake | `client/admission.zig` |
| Client read | `application/event_dispatcher/client.zig` |
| Client write | `client/send_coordinator.zig` |
| History result | `entrypoints/events/history_response.zig` |
| Proxy observation / exchange | `entrypoints/events/proxy_observation.zig`, `entrypoints/events/proxy_capture.zig` |
| Plugin effects | `entrypoints/events/plugin_effects.zig` |
| Agent expiry / description | `application/coordinators/` |
| Host metrics | `observability/system_metrics_coordinator.zig` |
| PTY input/response writes | `entrypoints/events/pane/input.zig`, `entrypoints/events/pane/response.zig` |
| PTY read / VT ingest | `entrypoints/events/pane/output.zig`, `entrypoints/events/pane/ingest.zig` |
| Observation / media result | `entrypoints/events/pane/observation.zig`, `entrypoints/events/pane/media.zig` |
| Child exit | `entrypoints/events/pane/exit.zig` |
| Telemetry | `observability/telemetry_tick_coordinator.zig` |

An entrypoint is a causal boundary, not permission to cross the interactive,
media or observation budget.
