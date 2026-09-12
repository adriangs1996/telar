//! One attached client's shared state: the model, the runtime transport, the
//! request lifecycle, configuration, plugins and the ports through which a
//! presentation adapter supplies its host. Adapters embed it, build it in
//! place and bind the ports before the first event.

const std = @import("std");
const OptionsType = @import("Options.zig");
const ClientInit = @import("ClientInit.zig");
const AppearanceThemesType = @import("appearance/AppearanceThemes.zig");
const max_expression_paste_bytes_module = @import("config/effects.zig").max_expression_paste_bytes;
const max_encoded_bytes = @import("input/input_namespace.zig").max_encoded_bytes;
const RuntimeTransportState = @import("connection/RuntimeTransportState.zig");
const ClientIdentityType = @import("telar-core").ClientIdentity;
const HostCapabilitiesType = @import("model/HostCapabilities.zig");
const TelemetryState = @import("resources/TelemetryState.zig");
const ClientLayoutsState = @import("resources/ClientLayoutsState.zig");
const StartupState = @import("controllers/session/State.zig");
const ModelType = @import("model/Model.zig");
const HistoryType = @import("workspace/History.zig");
const GenerationType = @import("config/Generation.zig");
const RegistryType = @import("plugins/Registry.zig");
const TrustStoreType = @import("telar-core").TrustStore;
const ConfigReloadState = @import("resources/ConfigReloadState.zig");
const SoundPlaybackType = @import("agents/SoundPlayback.zig");
const DeliveryType = @import("notifications/notifications.zig").Delivery;
const CaptureResourcesType = @import("attachments/CaptureResources.zig");
const OpeningType = @import("links/Opening.zig");
const PointerType = @import("links/Pointer.zig");
const LifecycleState = @import("connection/LifecycleState.zig");
const SchedulerType = @import("resources/Scheduler.zig");
const BarUpdatesState = @import("controllers/configuration/State.zig");
const LeasesType = @import("application/input/key_routing.zig").Leases;
const RegionType = @import("workspace/Region.zig");
const default_width = @import("layout/sidebar.zig").default_width;
const SoundPortType = @import("agents/SoundPort.zig");
const HostNotifierType = @import("notifications/HostNotifier.zig");
const LinkOpenerType = @import("links/LinkOpener.zig");
const CapturePortType = @import("attachments/CapturePort.zig");
const HostClipboardType = @import("application/panes/Clipboard.zig");
const HostGraphicsType = @import("graphics/HostGraphics.zig");
const GraphicsRetentionType = @import("graphics/GraphicsRetention.zig");
const HostChromeType = @import("presentation/HostChrome.zig");
const AttachmentCatalogPortType = @import("attachments/AttachmentCatalogPort.zig");
const AttachmentShelfType = @import("attachments/AttachmentShelf.zig");
const HostPresentationType = @import("presentation/HostPresentation.zig");
const HostTimersType = @import("resources/HostTimers.zig");
const BarCommandRunnerType = @import("bars/BarCommandRunner.zig");
const PluginWorkerRunnerType = @import("plugins/PluginWorkerRunner.zig");
const HostClockType = @import("resources/HostClock.zig");
const HostInputSourceType = @import("input/HostInputSource.zig");
const TransportDriverType = @import("connection/TransportDriver.zig");
const ConfigReloadWatcherType = @import("resources/ConfigReloadWatcher.zig");

comptime {
    std.debug.assert(max_expression_paste_bytes_module + 16 <= max_encoded_bytes);
}

const AttachedClient = @This();

io: std.Io,
gpa: std.mem.Allocator,
runtime_transport: RuntimeTransportState,
options: OptionsType,
client_identity: ClientIdentityType,
telemetry: TelemetryState,
client_layouts: ClientLayoutsState = .{},
startup: StartupState = .{},
model: ModelType,
navigation_history: HistoryType = .{},
lua_generation: ?*GenerationType,
plugin_registry: ?*RegistryType,
trust_store: ?*TrustStoreType,
reload: ConfigReloadState,
sound_playback: SoundPlaybackType,
notification_delivery: DeliveryType = .telar,
/// Whether the history palette lists automation-submitted commands too.
history_show_agent_commands: bool = false,
/// Whether Enter in the history palette runs the command instead of only
/// pasting it; shift+enter always does the opposite.
history_enter_runs: bool = false,
/// Whether the palette uses trigram substring matching instead of the
/// default fuzzy subsequence matching.
history_match_fts: bool = false,
/// Transient: the alternate flag of the list submission being finished.
list_submission_alternate: bool = false,
appearance_themes: AppearanceThemesType = .{},
clipboard_capture_resources: CaptureResourcesType = .{},
link_opening: OpeningType = .{},
link_pointer: PointerType = .{},
request_lifecycle: LifecycleState = .{},
sidebar_animation_scheduler: SchedulerType = .{},
notification_scheduler: SchedulerType = .{},
bar_updates: BarUpdatesState = .{},
/// Application key leases, owned by routing rather than by the host reader.
input_leases: LeasesType = .{},
/// Host ports, bound by the adapter before the first event.
sound_port: SoundPortType = undefined,
notifier: HostNotifierType = undefined,
link_opener: LinkOpenerType = undefined,
capture_port: CapturePortType = undefined,
host_clipboard: HostClipboardType = undefined,
host_graphics: HostGraphicsType = undefined,
graphics: GraphicsRetentionType = undefined,
chrome: HostChromeType = undefined,
attachment_catalog: AttachmentCatalogPortType = undefined,
attachment_shelf: AttachmentShelfType = undefined,
presentation: HostPresentationType = undefined,
timers: HostTimersType = undefined,
bar_runner: BarCommandRunnerType = undefined,
plugin_runner: PluginWorkerRunnerType = undefined,
clock: HostClockType = undefined,
host_input_source: HostInputSourceType = undefined,
transport_driver: TransportDriverType = undefined,
config_watcher: ConfigReloadWatcherType = undefined,

/// Builds the shared state in its final address. The model is megabytes, so
/// nothing here passes it by value. Ports remain unbound.
///
/// ```zig
/// try AttachedClient.init(&terminal.app, .{ .gpa = gpa, .io = io, .connection = connection, .host_size = size, .options = options });
/// ```
pub fn init(client: *AttachedClient, params: ClientInit) !void {
    const gpa = params.gpa;
    var capabilities: HostCapabilitiesType = .{
        .window_width_px = params.window_width_px,
        .window_height_px = params.window_height_px,
    };
    var host_size = params.host_size;
    const cell_size = capabilities.cellSize(host_size.cols, host_size.rows);
    host_size.cell_width_px = cell_size.width;
    host_size.cell_height_px = cell_size.height;
    try host_size.validate();
    const configuration_generation = if (params.options.lua_generation) |generation|
        generation.number
    else
        0;
    var runtime_transport_state = try RuntimeTransportState.init(gpa, params.connection);
    errdefer runtime_transport_state.deinit(gpa);

    client.* = .{
        .io = params.io,
        .gpa = gpa,
        .runtime_transport = runtime_transport_state,
        .options = params.options,
        .client_identity = params.client_identity,
        .telemetry = .init(params.io, params.options.endpoint),
        .model = undefined,
        .lua_generation = params.options.lua_generation,
        .plugin_registry = params.options.plugin_registry,
        .trust_store = params.options.trust_store,
        .reload = .{ .mtime_ns = params.options.config_mtime_ns },
        .sound_playback = .init(params.options.sound),
    };
    client.model = ModelType.initWithState(gpa, .{
        .pane_gaps = params.options.pane_gaps,
        .configuration_generation = configuration_generation,
        .bars = params.options.bars,
        .host_size = host_size,
        .host_capabilities = capabilities,
        .sidebar_width = default_width,
    });
    errdefer client.model.deinit();
    try client.model.history_palette.prepare(gpa);
    _ = client.model.setSidebarVisible(params.options.sidebar_visible);
}

/// Returns the workbench grid the adapter currently publishes.
/// Example: `const region = client.geometry();`.
pub fn geometry(client: *const AttachedClient) RegionType {
    return client.chrome.region();
}

/// Releases shared state. The adapter cancels its tasks and frees its own
/// resources first; nothing here may still be borrowed by a worker.
///
/// ```zig
/// terminal.app.deinit();
/// ```
pub fn deinit(client: *AttachedClient) void {
    const gpa = client.gpa;
    client.telemetry.deinit(client.io);
    client.reload.deinit(gpa);
    client.clipboard_capture_resources.deinit(gpa);
    if (client.lua_generation) |generation| {
        generation.deinit();
    }
    if (client.plugin_registry) |registry| {
        gpa.destroy(registry);
    }
    if (client.trust_store) |store| {
        gpa.destroy(store);
    }
    client.model.deinit();
    client.runtime_transport.deinit(gpa);
}
