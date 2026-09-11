//! One attached client: the long-lived objects `run` owns by pointer, plus
//! every piece of pending-request and frame-pacing state that used to be a
//! loose local threaded through fourteen-argument calls.

const host_inputs = @import("controllers/input/host_inputs.zig");
const OptionsType = @import("Options.zig");
const AppearanceThemesType = @import("AppearanceThemes.zig");
const std = @import("std");
const max_expression_paste_bytes_module = @import("telar-client").max_expression_paste_bytes;
const max_encoded_bytes = @import("telar-client").max_encoded_bytes;
const CompressionType = @import("../graphics/Compression.zig");
const BarUpdatesCompletion = @import("controllers/configuration/BarUpdatesCompletion.zig");
const config_reload = @import("resources/config_reload.zig");
const PluginActionsCompletion = @import("controllers/configuration/PluginActionsCompletion.zig");
const CompletionType = @import("controllers/host/Completion.zig");
const RuntimeTransportState = @import("telar-client").RuntimeTransportState;
const OutputType = @import("resources/Output.zig");
const ClientIdentityType = @import("telar-core").ClientIdentity;
const TelemetryState = @import("resources/TelemetryState.zig");
const ClientLayoutsState = @import("resources/ClientLayoutsState.zig");
const StateType = @import("controllers/session/State.zig");
const HostNegotiationState = @import("resources/HostNegotiationState.zig");
const Presenter = @import("presentation/Presenter.zig");
const PresentationState = @import("presentation/State.zig");
const ModelType = @import("telar-client").Model;
const HistoryType = @import("telar-client").History;
const kitty_delivery = @import("../graphics/kitty_delivery.zig");
const InputState = @import("controllers/input/State.zig");
const GenerationType = @import("../config/Generation.zig");
const RegistryType = @import("../plugins/Registry.zig");
const TrustStoreType = @import("telar-core").TrustStore;
const ConfigReloadState = @import("resources/ConfigReloadState.zig");
const capabilities_module = @import("../graphics/capabilities.zig");
const PlaybackType = @import("../sound/Playback.zig");
const DeliveryType = @import("telar-client").Delivery;
const CaptureResourcesType = @import("telar-client").CaptureResources;
const OpeningType = @import("telar-client").Opening;
const PointerType = @import("telar-client").Pointer;
const LifecycleState = @import("telar-client").LifecycleState;
const SchedulerType = @import("controllers/notifications/Scheduler.zig");
const ClientScheduler = @import("telar-client").Scheduler;
const ConfigurationState = @import("controllers/configuration/State.zig");
const Params = @import("Params.zig");
const HostCapabilitiesType = @import("telar-client").HostCapabilities;
const ScreenType = @import("../presentation/Screen.zig");
const default_width = @import("telar-client").default_width;
const presentation_lifecycle = @import("presentation/presentation_lifecycle.zig");
const RegionType = @import("telar-client").Region;

pub const InputRouter = host_inputs.Router;
pub const InputChunk = @import("controllers/input/Chunk.zig");

comptime {
    std.debug.assert(max_expression_paste_bytes_module + 16 <= max_encoded_bytes);
}

pub const Options = @import("Options.zig");

pub const AppearanceThemes = @import("AppearanceThemes.zig");

pub const ClientEvent = union(enum) {
    /// Bytes read into `host_input.chunk`; zero is EOF.
    input: anyerror!u16,
    input_timeout: anyerror!void,
    binding_timeout: anyerror!void,
    capability_timeout: anyerror!void,
    resized: anyerror!void,
    server: anyerror![]u8,
    sent: anyerror!void,
    draw: anyerror!void,
    media_tick: anyerror!void,
    host_written: anyerror!void,
    compression_done: *CompressionType,
    sidebar_animation_tick: anyerror!void,
    notification_tick: anyerror!void,
    bar_tick: anyerror!void,
    bar_command: BarUpdatesCompletion,
    sound_played: anyerror!void,
    notified: anyerror!void,
    telemetry_tick: anyerror!void,
    telemetry_written: anyerror!void,
    config_reload: anyerror!config_reload.ConfigReload,
    plugin_result: PluginActionsCompletion,
    clipboard_image: CompletionType,
    link_opened: anyerror!void,
};

const client_event_count = @typeInfo(ClientEvent).@"union".fields.len;

io: std.Io,
gpa: std.mem.Allocator,
runtime_transport: RuntimeTransportState,
writer: *std.Io.Writer,
output: ?OutputType = null,
select: std.Io.Select(ClientEvent),
select_storage: [client_event_count]ClientEvent = undefined,
options: OptionsType,
client_identity: ClientIdentityType,
telemetry: TelemetryState,
client_layouts: ClientLayoutsState = .{},
startup: StateType = .{},
host_negotiation: HostNegotiationState = .{},
presenter: Presenter,
view: PresentationState,
model: ModelType,
navigation_history: HistoryType = .{},
graphics_store: kitty_delivery.Store,
host_input: InputState,
lua_generation: ?*GenerationType,
plugin_registry: ?*RegistryType,
trust_store: ?*TrustStoreType,
reload: ConfigReloadState,
sidebar_rendering: capabilities_module.SidebarRendering,
sound_playback: PlaybackType,
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
notification_scheduler: ClientScheduler = .{},
bar_updates: ConfigurationState = .{},

const Client = @This();

/// Creates a heap-owned client (the tab models alone are megabytes) and
/// takes ownership of the configuration generation, plugin registry and
/// trust store carried inside `params.options`; `deinit` releases them.
pub fn init(params: Params) !*Client {
    const gpa = params.gpa;
    const client = try gpa.create(Client);
    errdefer gpa.destroy(client);
    var capabilities: HostCapabilitiesType = .{
        .window_width_px = params.window_width_px,
        .window_height_px = params.window_height_px,
    };
    var host_size = params.host_size;
    const cell_size = capabilities.cellSize(host_size.cols, host_size.rows);
    host_size.cell_width_px = cell_size.width;
    host_size.cell_height_px = cell_size.height;
    try host_size.validate();
    var screen = try ScreenType.init(gpa, host_size.cols, host_size.rows);
    errdefer screen.deinit();
    var view = try PresentationState.initWithAppearance(
        gpa,
        .{ .width = host_size.cols, .height = host_size.rows },
        .{ .theme = params.options.theme, .icons = params.options.icon_theme },
    );
    errdefer view.deinit();
    view.setSidebarLayout(params.options.sidebar_visible, default_width);
    try view.configureSidebar(
        params.options.sidebar_rendering,
        .{
            .support = capabilities.images,
            .cell_width = cell_size.width,
            .cell_height = cell_size.height,
        },
    );
    const configuration_generation = if (params.options.lua_generation) |generation|
        generation.number
    else
        0;
    var model = ModelType.initWithState(gpa, .{
        .pane_gaps = params.options.pane_gaps,
        .configuration_generation = configuration_generation,
        .bars = params.options.bars,
        .host_size = host_size,
        .host_capabilities = capabilities,
        .sidebar_width = default_width,
    });
    errdefer model.deinit();
    try model.history_palette.prepare(gpa);
    _ = model.setSidebarVisible(params.options.sidebar_visible);
    var graphics_store = if (params.options.host_shared_memory)
        kitty_delivery.Store.initSharedMemory(gpa)
    else
        kitty_delivery.Store.init(gpa);
    errdefer graphics_store.deinit();
    var runtime_transport_state = try RuntimeTransportState.init(gpa, params.connection);
    errdefer runtime_transport_state.deinit(gpa);
    const host_input = try InputState.init(params.input_file, .{
        .prefix = params.options.prefix,
        .bindings = params.options.bindings,
        .escape_timeout_ns = params.options.input_escape_timeout_ns,
        .sequence_timeout_ns = params.options.input_sequence_timeout_ns,
    });
    var output: ?OutputType = if (params.async_output) try .init(gpa, params.writer) else null;
    if (output) |*value| {
        value.fast_write = params.fast_output;
    }
    errdefer if (output) |*value| {
        value.deinit();
    };

    client.* = .{
        .io = params.io,
        .gpa = gpa,
        .runtime_transport = runtime_transport_state,
        .writer = params.writer,
        .output = output,
        .select = undefined,
        .options = params.options,
        .client_identity = params.client_identity,
        .telemetry = .init(params.io, params.options.endpoint),
        .presenter = undefined,
        .view = view,
        .model = model,
        .graphics_store = graphics_store,
        .host_input = host_input,
        .lua_generation = params.options.lua_generation,
        .plugin_registry = params.options.plugin_registry,
        .trust_store = params.options.trust_store,
        .sidebar_rendering = params.options.sidebar_rendering,
        .sound_playback = .init(params.options.sound),
        .reload = .{ .mtime_ns = params.options.config_mtime_ns },
    };
    if (client.output) |*value| {
        client.writer = &value.writer;
        client.graphics_store.delivery.compression_scheduler = .{ .context = client, .start = scheduleCompression };
    }

    // The select's storage lives inside the heap-stable client, so the
    // select can only be built once the client's address exists.
    client.select = std.Io.Select(ClientEvent).init(params.io, &client.select_storage);
    // The presenter borrows the select and metrics, whose heap addresses
    // only exist once the client does.
    client.presenter = .{
        .io = params.io,
        .scheduler = .{
            .context = client,
            .draw = scheduleDraw,
            .draw_now = drawNow,
            .media = scheduleMedia,
        },
        .metrics = &client.telemetry.metrics,
        .screen = screen,
        .compositor = .init(gpa),
    };
    return client;
}

fn scheduleCompression(context: *anyopaque, job: *CompressionType) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    try client.select.concurrent(.compression_done, CompressionType.run, .{job});
}

fn scheduleDraw(context: *anyopaque, deadline_ns: u64) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    try client.select.concurrent(.draw, waitForPresentation, .{ client.io, deadline_ns });
}

fn drawNow(context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    try presentation_lifecycle.presentNow(client);
}

fn scheduleMedia(context: *anyopaque, deadline_ns: u64) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    try client.select.concurrent(.media_tick, waitForPresentation, .{ client.io, deadline_ns });
}

fn waitForPresentation(io: std.Io, deadline_ns: u64) anyerror!void {
    const deadline = std.Io.Timestamp.fromNanoseconds(@intCast(deadline_ns)).withClock(.awake);
    try deadline.wait(io);
}

/// Cancels every in-flight select task first — the reload task publishes
/// into the orphan slots — then releases the orphans, the owned
/// configuration objects, and every buffer.
/// Returns the presentation-supplied region for a synchronous application call.
/// Example: `const region = client.geometry();`.
pub fn geometry(client: *const Client) RegionType {
    return client.view.geometry();
}

pub fn deinit(client: *Client) void {
    const gpa = client.gpa;
    client.select.cancelDiscard();
    if (client.output) |*output| {
        output.deinit();
    }

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
    client.graphics_store.deinit();
    client.model.deinit();
    client.view.deinit();
    client.presenter.deinit();
    client.runtime_transport.deinit(gpa);
    gpa.destroy(client);
}
