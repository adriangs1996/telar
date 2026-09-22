# AttachedClient model extraction audit

This audit covers all 50 concrete type imports in `AttachedClient.zig` before
this extraction. Twenty-one now come from `model`; the remaining 29 have the
service or assembly dependencies listed below. No candidate in that inventory
is deferred.

The 21 data roots require 175 files of definitions, algorithms and tests.
Their consumers now use the named `model` module. Internal helpers stay private;
71 of these files have consumers through the public module API.

## Data roots moved to model

| Former import | Canonical definition |
| --- | --- |
| `AppearanceThemesType` | [`data.AppearanceThemes`](../src/model/appearance/AppearanceThemes.zig) |
| `ClientLayoutsState` | [`data.ClientLayoutsState`](../src/model/resources/ClientLayoutsState.zig) |
| `ModelType` | [`data.Model`](../src/model/state/Model.zig) |
| `HistoryType` | [`data.NavigationHistory`](../src/model/workspace/NavigationHistory.zig) |
| `CaptureResourcesType` | [`data.CaptureResources`](../src/model/attachments/CaptureResources.zig) |
| `OpeningType` | [`data.Opening`](../src/model/links/Opening.zig) |
| `BarUpdatesState` | [`data.BarUpdatesState`](../src/model/bars/BarUpdatesState.zig) |
| `BarConfiguration` | [`data.BarConfiguration`](../src/model/bars/BarConfiguration.zig) |
| `MultiplexerModel` | [`data.MultiplexerModel`](../src/model/workspace/MultiplexerModel.zig) |
| `Tab` | [`data.Tab`](../src/model/workspace/Tab.zig) |
| `ConnectionDelivery` | [`data.ConnectionDelivery`](../src/model/connection/ConnectionDelivery.zig) |
| `Pane` | [`data.Pane`](../src/model/panes/Pane.zig) |
| `LayoutsType` | [`data.SavedLayouts`](../src/model/workspace/SavedLayouts.zig) |
| `ResultsType` | [`data.Results`](../src/model/state/Results.zig) |
| `SourcesType` | [`data.Sources`](../src/model/state/Sources.zig) |
| `PluginOverride` | [`data.PluginOverride`](../src/model/resources/PluginOverride.zig) |
| `PluginActionsCompletion` | [`data.PluginActionsCompletion`](../src/model/plugins/PluginActionsCompletion.zig) |
| `PluginResultType` | [`data.PluginResult`](../src/model/application/input/PluginResult.zig) |
| `CaptureType` | [`data.Capture`](../src/model/attachments/Capture.zig) |
| `Completion` | [`data.Completion`](../src/model/operations/host/Completion.zig) |
| `CaptureRequestType` | [`data.CaptureRequest`](../src/model/attachments/CaptureRequest.zig) |

## Imports retained in the client

Each host port below contains an adapter context and callable functions.
The other entries assemble services or own live resources; placing them in
`model` would introduce the client, host or Lua dependency being separated.

| Import | Definition | Reason |
| --- | --- | --- |
| `Options` | [Source](../src/client/Options.zig) | Client assembly options include live Lua generation, registry and trust-store references. |
| `ClientInit` | [Source](../src/client/ClientInit.zig) | Constructs a connection with its allocator, I/O context, socket channel and client options. |
| `RuntimeTransportState` | [Source](../src/client/connection/RuntimeTransportState.zig) | Owns the connected socket channel and performs runtime reads and writes. |
| `TelemetryState` | [Source](../src/client/resources/TelemetryState.zig) | Owns the diagnostics sink and its write buffer; initialization opens the sink and teardown closes it. |
| `Generation` | [Source](../src/client/config/Generation.zig) | Owns the Lua VM and loads and evaluates configuration code. |
| `Registry` | [Source](../src/client/plugins/Registry.zig) | Loads plugin packages through the configuration and Lua services. |
| `ConfigReloadState` | [Source](../src/client/resources/ConfigReloadState.zig) | Retains in-flight reload resources and frees orphan generations, registries and trust stores after tasks are joined. |
| `SoundPort` | [Source](../src/client/agents/SoundPort.zig) | Invokes host sound playback. |
| `HostNotifier` | [Source](../src/client/notifications/HostNotifier.zig) | Delivers notifications through the host adapter. |
| `LinkOpener` | [Source](../src/client/links/LinkOpener.zig) | Requests external link opening from the host. |
| `CapturePort` | [Source](../src/client/attachments/CapturePort.zig) | Queries support and starts bounded clipboard capture work in the adapter. |
| `HostClipboard` | [Source](../src/client/application/panes/Clipboard.zig) | Writes selections to the host clipboard. |
| `HostGraphics` | [Source](../src/client/graphics/HostGraphics.zig) | Delivers graphics operations to the presentation adapter. |
| `GraphicsRetention` | [Source](../src/client/graphics/GraphicsRetention.zig) | Retains and releases graphics resources owned by the adapter. |
| `HostChrome` | [Source](../src/client/presentation/HostChrome.zig) | Configures host chrome, appearance and layout, and queries pointer hit testing. |
| `AttachmentCatalogPort` | [Source](../src/client/attachments/AttachmentCatalogPort.zig) | Queries and changes attachments through the host-owned catalog. |
| `AttachmentShelf` | [Source](../src/client/attachments/AttachmentShelf.zig) | Adopts captures and operates the host attachment shelf and modal. |
| `HostPresentation` | [Source](../src/client/presentation/HostPresentation.zig) | Controls presentation size and input pacing, and queries delivered geometry. |
| `HostTimers` | [Source](../src/client/resources/HostTimers.zig) | Arms deadlines on the host event loop, including bar scheduling. |
| `BarCommandRunner` | [Source](../src/client/bars/BarCommandRunner.zig) | Starts external bar-command jobs. |
| `PluginWorkerRunner` | [Source](../src/client/plugins/PluginWorkerRunner.zig) | Schedules plugin execution jobs through the adapter. |
| `PathCompletionRunner` | [Source](../src/client/completion/PathCompletionRunner.zig) | Schedules filesystem completion work through the adapter. |
| `FaviconRunner` | [Source](../src/client/completion/FaviconRunner.zig) | Schedules favicon lookup work through the adapter. |
| `HostClock` | [Source](../src/client/resources/HostClock.zig) | Reads the host local time. |
| `HostInputSource` | [Source](../src/client/input/HostInputSource.zig) | Controls host input reading, binding adoption and thread navigation. |
| `TransportDriver` | [Source](../src/client/connection/TransportDriver.zig) | Schedules asynchronous reads and sends for RuntimeTransportState. |
| `ConfigReloadWatcher` | [Source](../src/client/resources/ConfigReloadWatcher.zig) | Starts host configuration watching. |
| `Adoption` | [Source](../src/client/resources/Adoption.zig) | Transfers ownership of validated generations, registries and trust stores; frees rejected adoptions. |
| `ConfiguredPlugins` | [Source](../src/client/plugins/ConfiguredPlugins.zig) | Queries configured entries against the live loaded plugin registry. |

## State and effects

`BarUpdatesState` used to arm the host timer itself. Its deadlines, pending
masks and command identities now belong to `model`. `HostTimers.rearmBars`
performs the host scheduling and preserves reservation rollback when scheduling
fails. The existing failure, retry and coalescing test follows that operation.

`ConnectionDelivery` and `Outbox` contain bounded message state. The socket
and asynchronous driver remain in the client. `Capture` owns bounded bytes
and their deallocation; it does not perform host capture. An allocator or a
`deinit` method alone does not make data a host service.

The move does not introduce global state. `AttachedClient` still owns its
instances, and each connection retains its own state and resource lifetimes.

## Verification

Run `zig build install test build-widget` for the application, widget and
test suites. The build also checks model and client dependency boundaries and
Zig source layout. Compare verbose test logs with `tools/compare_zig_tests.py`
to detect lost named tests when their module ownership changes.

Validated on 2026-09-22:

- `zig build install test build-widget --summary all --verbose`: 145/145 steps
  succeeded; 3020 tests passed and 2 skipped.
- `zig build check --summary all`: 90/90 steps succeeded.
- Test metadata comparison: all 2530 unique named tests preserved, no additions
  or losses. Four duplicate test executions were removed.
- Model and client boundary checks and source layout checks passed.
