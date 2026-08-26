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

## Runtime capabilities

| Capability | Root | Owns |
| --- | --- | --- |
| Runtime | `src/backend/runtime/root.zig` | Runtime event loop, client sessions and cross-capability orchestration |
| Pane | `src/backend/pane/root.zig` | One child process, PTY terminal state, cell projection and pane lifecycle |
| PTY | `src/backend/pty/root.zig` | Child process and pseudo-terminal platform adapter |
| Media | `src/backend/media/root.zig` | Bounded child Kitty-graphics ingestion |
| Process | `src/backend/process/root.zig` | Bounded foreground-process observation |
| Agent | `src/backend/agent/root.zig` | Agent evidence precedence and projected agent state |
| History | `src/backend/history/root.zig` | Command observation, queries and durable storage |
| Proxy | `src/backend/proxy/root.zig` | Network observation and TLS proxy actors |
| Transport | `src/backend/transport/root.zig` | Runtime side of local connection and handshake |

The runtime root is an orchestrator. High fan-out is expected there and is a
defect in a leaf capability unless an invariant requires it.

## Client capabilities

| Capability | Root | Owns |
| --- | --- | --- |
| Client | `src/frontend/client/root.zig` | Client event loop and cross-capability orchestration |
| Input | `src/frontend/input/root.zig` | Host input parsing, key routing, semantic actions and editing |
| Workspace | `src/frontend/workspace/root.zig` | Disposable tabs, pane layout and cell composition |
| Presentation | `src/frontend/presentation/root.zig` | Host screen diff, frame application and pacing |
| Graphics | `src/frontend/graphics/root.zig` | Host graphics capabilities, transfer state and overlays |
| UI | `src/frontend/ui/root.zig` | Client-only focus, hits and theme values |
| Widgets | `src/frontend/widgets/root.zig` | Chrome and interaction surfaces |
| Config | `src/frontend/config/root.zig` | Typed configuration and the client-owned Lua generation |
| Plugins | `src/frontend/plugins/root.zig` | Plugin registry, protocol and isolated worker execution |
| Platform | `src/frontend/platform/root.zig` | Host TTY and resize adapters |
| Transport | `src/frontend/transport/root.zig` | Client side of local connection and handshake |

The client root is an orchestrator. Capability code must not import it to get
at client state.

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
frontend/client       -> input, workspace, presentation, graphics, ui,
                         widgets, config, plugins, platform, transport
frontend/input        -> presentation
frontend/workspace    -> input, presentation, ui
frontend/graphics     -> workspace, presentation, ui, widgets
frontend/config       -> input, graphics, ui
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

All client handlers are in `src/frontend/client/root.zig`.

| Event | Entrypoint |
| --- | --- |
| Host terminal bytes | `Client.handleHostInput` |
| Input parser deadline | `Client.handleInputTimeoutEvent` |
| Partial binding deadline | `Client.handleBindingTimeoutEvent` |
| Host capability deadline | `Client.handleCapabilityTimeoutEvent` |
| Host resize | `Client.handleResizeEvent` |
| Runtime socket read | `Client.handleServerEvent` |
| Completed socket write | `Client.handleSentEvent` |
| Scheduled draw | `Client.handleDrawEvent` -> `Client.presentDue` |
| Sidebar animation tick | `Client.handleSidebarAnimationEvent` |
| Notification tick | `Client.handleNotificationTickEvent` |
| Telemetry tick/write | `Client.handleTelemetryTickEvent`, `Client.handleTelemetryWrittenEvent` |
| Config reload | `Client.handleConfigReloadEvent` |
| Plugin worker result | `Client.handlePluginResultEvent` |

### Runtime

All runtime handlers are in `src/backend/runtime/root.zig`.

| Event | Entrypoint |
| --- | --- |
| Accepted socket | `Server.handleAcceptedEvent` |
| Completed handshake | `Server.handleHandshakenEvent` |
| Client socket read | `Server.handleClientMessageEvent` |
| Completed client write | `Server.handleClientSentEvent` |
| History worker result | `Server.handleHistoryResponseEvent` |
| Proxy observation | `Server.handleProxyEvent` |
| Agent expiry tick | `Server.handleAgentTickEvent` |
| System metrics tick | `Server.handleMetricsTickEvent` |
| Completed PTY input write | `Server.handlePaneInputWrittenEvent` |
| Completed terminal response write | `Server.handlePaneResponseWrittenEvent` |
| PTY read | `Server.handlePaneOutputEvent` |
| Completed VT ingestion | `Server.handlePaneIngestedEvent` |
| Observation worker result | `Server.handlePaneObservedEvent` |
| Media worker result | `Server.handlePaneMediaEvent` |
| Child exit | `Server.handlePaneExitEvent` |
| Telemetry tick/write | `Server.handleTelemetryTickEvent`, `Server.handleTelemetryWrittenEvent` |

Entrypoints name causal boundaries. They do not imply that synchronous work may
cross the interactive, media and observation budgets.
