# Capability map

Telar is organized first by process ownership, then by capability. A
capability directory exposes its supported surface from `root.zig`. Imports
between capabilities go through those roots; files beside a root are internal
implementation.

This map answers "where does this state belong?". The maps in `docs/flows/`
answer "what happens after this external event?".

## Shared core

| Capability | Root | Responsibility |
| --- | --- | --- |
| Schema | `src/core/schema/root.zig` | Bounded runtime-client messages and their encoding |
| UI values | `src/core/ui/root.zig` | Cells, buffers, geometry and text values shared across the process boundary |
| Transport | `src/core/transport/root.zig` | Framed byte-stream channels and local endpoint values |

The remaining files in `src/core/` are small pure support modules. Core owns no
live runtime or client state and imports neither process package.

## Executable entrypoints

| Capability | Root | Responsibility |
| --- | --- | --- |
| Command line | `src/cli/root.zig` | Parse commands and own each process-specific startup flow |

`src/main.zig` collects process arguments and selects one command-line
entrypoint. The server entrypoint selects production dependencies and
initializes the public runtime instance; the client entrypoint prepares the
disposable frontend process.

## Runtime capabilities

| Capability | Root | Owns |
| --- | --- | --- |
| Runtime | `src/backend/runtime/root.zig` | Public lifecycle for one runtime instance |
| Pane | `src/backend/pane/root.zig` | One child process, PTY terminal state, cell projection and pane lifecycle |
| PTY | `src/backend/pty/root.zig` | Verified child launch, PTY I/O and child lifecycle |
| Media | `src/backend/media/root.zig` | Bounded child Kitty-graphics ingestion |
| Process | `src/backend/process/root.zig` | Native process metadata and bounded foreground-process observation |
| Agent | `src/backend/agent/root.zig` | Agent evidence precedence and projected agent state |
| History | `src/backend/history/root.zig` | Command observation, queries and durable storage |
| Proxy | `src/backend/proxy/root.zig` | Network observation and TLS proxy actors |
| Transport | `src/backend/transport/root.zig` | Runtime side of local connection and handshake |

`src/cli/server.zig` selects the production dependencies and initializes the
public runtime instance. Behind `src/backend/runtime/root.zig`, the lifetime is
split without changing that public contract:

| Runtime part | File | Responsibility |
| --- | --- | --- |
| Runtime composition | `src/backend/runtime/instance.zig` | Acquire, compose, run and tear down one runtime |
| Physical resources | `src/backend/runtime/resources/root.zig` | Own concrete process resources and startup rollback |
| Event loop | `src/backend/runtime/event_loop.zig` | Own bounded event storage, selection and stop coordination |
| Application | `src/backend/runtime/application/root.zig` | Own the live model, client application state and cross-capability invariants |
| Runtime model | `src/backend/runtime/application/model.zig` | Hold authoritative semantic state without implementing behavior |
| Pane launcher | `src/backend/runtime/application/pane_launcher.zig` | Commit or roll back pane creation and actor startup as one transaction |
| Event sources | `src/backend/runtime/event_sources.zig` | Arm infrastructure work that produces runtime events |
| Event dispatcher | `src/backend/runtime/application/event_dispatcher/root.zig` | Classify completions and delegate them to capability-specific adapters |
| Operation scheduler | `src/backend/runtime/application/operation_scheduler.zig` | Start bounded asynchronous work requested by the application |
| Request dispatch | `src/backend/runtime/application/request_dispatch.zig` | Build request-scoped controllers and application handlers |

Below that composition layer, directory names describe runtime roles rather
than repeating backend capability names:

| Runtime role | Location | Responsibility |
| --- | --- | --- |
| Application commands | `src/backend/runtime/application/commands/` | Synchronous use cases and transaction policy |
| Application queries | `src/backend/runtime/application/queries/` | Read-only application operations |
| Application coordinators | `src/backend/runtime/application/coordinators/root.zig` | Description work and agent evidence expiry |
| Request entrypoints | `src/backend/runtime/entrypoints/requests/` | Wire translation, expected-error mapping and response enqueueing |
| Event entrypoints | `src/backend/runtime/entrypoints/events/root.zig` | Completion policy for actors and asynchronous resources |
| Resource owners | `src/backend/runtime/resources/root.zig` | Startup, stable ownership and teardown of physical resources |
| Attachment | `src/backend/runtime/attachment/root.zig` | Per-client pane projection and acknowledgement |
| Client coordination | `src/backend/runtime/client/root.zig` | Admission, request routing and send completion |
| Delivery | `src/backend/runtime/delivery/root.zig` | Bounded response scheduling, encoding and send transactions |
| Lifecycle | `src/backend/runtime/lifecycle/root.zig` | Stop authority, external stop signal and ordered teardown |
| Observability | `src/backend/runtime/observability/root.zig` | Host metrics and diagnostic telemetry |

High fan-out is restricted to composition, actor binding and request dispatch.
It is a defect in a leaf capability unless an indivisible invariant requires
it.

## Client capabilities

| Capability | Root | Owns |
| --- | --- | --- |
| Client | `src/frontend/client/root.zig` | Client event loop, disposable semantic state, observability lifecycle and cross-capability orchestration |
| Agents | `src/frontend/agents/root.zig` | Agent identities and the bounded client replica of runtime agent state |
| Sound | `src/frontend/sound/root.zig` | Bounded host-audio playback policy, queue and platform worker |
| Input | `src/frontend/input/root.zig` | Host input parsing, key routing, semantic actions and editing |
| Workspace | `src/frontend/workspace/root.zig` | Disposable tabs, pane layout and immutable pane composition primitives |
| Presentation | `src/frontend/presentation/root.zig` | Host screen diff, frame application and pacing |
| Graphics | `src/frontend/graphics/root.zig` | Host graphics transfer state, renderer policy and overlays |
| UI | `src/frontend/ui/root.zig` | Client-only focus, hits and theme values |
| Widgets | `src/frontend/widgets/root.zig` | Chrome and interaction surfaces |
| Config | `src/frontend/config/root.zig` | Typed configuration and the client-owned Lua generation |
| Plugins | `src/frontend/plugins/root.zig` | Plugin registry, protocol and isolated worker execution |
| Platform | `src/frontend/platform/root.zig` | Host TTY and resize adapters |
| Transport | `src/frontend/transport/root.zig` | Client side of local connection and handshake |

The client root is an orchestrator. Capability code must not import it to get
at client state.

The client-internal `presentation_projection` adapter is the only concrete
`Client` to `Presenter` boundary. `Presenter` receives immutable semantic
inputs and explicit presentation resources; its compositor owns every
last-painted cache.

## Dependency direction

```text
external event
      |
      v
client/root.zig                    backend/runtime/root.zig
      |                                      |
      v                                      v
frontend capability roots          backend capability roots
      |                                      |
      +---------------+  +-------------------+
                      v  v
                  telar-core
```

The important current edges are:

```text
frontend/client       -> agents, sound, input, workspace, presentation,
                         graphics, ui, widgets, config, plugins, platform,
                         transport
frontend/input        -> presentation
frontend/workspace    -> input, presentation, ui
frontend/widgets      -> agents, workspace, attachments, ui
frontend/graphics     -> workspace, presentation, ui, widgets
frontend/config       -> sound, input, graphics, ui
frontend/plugins      -> input, config

backend/runtime       -> pane, pty, media, process, agent, history, proxy,
                         transport
backend/pane          -> pty, media, process, history
backend/agent         -> pane, history
```

Every arrow also depends on core where it uses shared values or messages. A new
edge should be justified by ownership or an indivisible invariant. A dependency
cycle between capability roots is rejected.

## Process entrypoints

The event loops contain only this dispatch table and termination checks. The
named handlers own ordering, state transitions and rescheduling.

### Client

The client root exports the loop; its internal adapters own the named event
entrypoints below.

| Event | Entrypoint |
| --- | --- |
| Host terminal bytes | [`host_inputs.handleRead`](flows/host-input-to-screen.md) |
| Input parser deadline | [`host_inputs.handleInputTimeout`](flows/host-input-to-screen.md) |
| Partial binding deadline | [`host_inputs.handleBindingTimeout`](flows/host-input-to-screen.md) |
| Host capability deadline | [`host_capabilities.handleExpiry`](flows/host-capabilities.md) |
| Host resize | [`host_resizes.handle`](flows/host-resize.md) |
| Runtime socket read | [`runtime_transport.handleRead`](flows/runtime-transport.md) |
| Completed socket write | [`runtime_transport.handleSent`](flows/runtime-transport.md) |
| Scheduled draw | [`presentation_lifecycle.handleDraw`](flows/presentation-lifecycle.md) |
| Scheduled media pass | [`presentation_lifecycle.handleMediaTick`](flows/presentation-lifecycle.md) |
| Sidebar animation tick | [`sidebar_animations.handleTick`](flows/sidebar-animation.md) |
| Notification tick | [`notifications.handleTick`](flows/notifications.md) |
| Agent sound completion | [`agent_sounds.handlePlayed`](flows/agent-sound.md) |
| Telemetry tick/write | [`telemetry.handleTick`, `telemetry.handleWritten`](flows/client-telemetry.md) |
| Config reload | [`config_reloads.handle`](flows/config-reload.md) |
| Plugin worker result | [`plugin_actions.complete`](flows/plugin-action.md) |
| Clipboard image result | [`clipboard_images.complete`](flows/clipboard-image.md) |

### Runtime

`Runtime.run` receives every event and handles only stop completion. Every
non-stop event crosses `application.handle` into
`event_dispatcher.Dispatcher.handle`, which delegates to the owning adapter.

| Event | Owner after classification |
| --- | --- |
| Accepted socket / completed handshake | `runtime/client/admission.zig` |
| Client socket read | `runtime/application/event_dispatcher/client.zig` -> `Application.dispatchClientMessage` |
| Completed client write | `runtime/client/send_coordinator.zig` |
| History worker result | `runtime/entrypoints/events/history_response.zig` |
| Proxy observation | `runtime/entrypoints/events/proxy_observation.zig` |
| Agent expiry / description completion | `runtime/application/coordinators/agent_*.zig` |
| System metrics tick | `runtime/observability/system_metrics_coordinator.zig` |
| Completed PTY input write | `runtime/entrypoints/events/pane/input.zig` |
| Completed terminal response write | `runtime/entrypoints/events/pane/response.zig` |
| PTY read | `runtime/entrypoints/events/pane/output.zig` |
| Completed VT ingestion | `runtime/entrypoints/events/pane/ingest.zig` |
| Observation worker result | `runtime/entrypoints/events/pane/observation.zig` |
| Media worker result | `runtime/entrypoints/events/pane/media.zig` |
| Child exit | `runtime/entrypoints/events/pane/exit.zig` |
| Telemetry tick / write | `runtime/observability/telemetry_tick_coordinator.zig`, telemetry state |

Entrypoints name causal boundaries. They do not imply that synchronous work may
cross the interactive, media and observation budgets.
