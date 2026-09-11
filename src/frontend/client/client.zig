//! One attached client: the long-lived objects `run` owns by pointer, plus
//! every piece of pending-request and frame-pacing state that used to be a
//! loose local threaded through fourteen-argument calls.

const std = @import("std");
const core = @import("telar-core");
const input_capability = @import("../input/root.zig");
const presentation = @import("../presentation/root.zig");
const workspace_capability = @import("../workspace/root.zig");
const graphics = @import("../graphics/root.zig");
const attachments = @import("../attachments/root.zig");
const bars_capability = @import("../bars/root.zig");
const client_telemetry = @import("resources/telemetry.zig");
const client_layout_resource = @import("resources/client_layouts.zig");
const client_view = @import("presentation/view.zig");
const client_model = @import("telar-client").model;
const lua_config = @import("../config/root.zig");
const link_capability = @import("../links/root.zig");
const sound_capability = @import("../sound/root.zig");
const theme_capability = @import("../ui/theme_support.zig");
const notification_capability = @import("telar-client").notifications;
pub const keybind = input_capability.keybind;
pub const kitty = graphics.kitty;
const toast_graphics = graphics.toast;
const navigation = workspace_capability.navigation;
const term = presentation.screen;
const plugin_broker = @import("../plugins/root.zig");
const ui_capability = @import("../ui/root.zig");
pub const icons = ui_capability.icons;
pub const theme = ui_capability.theme;

pub const Io = std.Io;
pub const File = Io.File;
pub const schema = core.schema;

pub const ConfiguredBinding = lua_config.ConfiguredBinding;
pub const InputRouter = host_inputs.Router;
pub const InputChunk = host_inputs.Chunk;

comptime {
    std.debug.assert(lua_config.max_expression_paste_bytes + 16 <= runtime_transport_mod.max_input_bytes);
}

pub const Options = @import("Options.zig");

const clipboard_images = @import("controllers/host/clipboard_images.zig");
const bar_updates_controller = @import("controllers/configuration/bar_updates.zig");
const config_reload = @import("resources/config_reload.zig");
const host_inputs = @import("controllers/input/host_inputs.zig");
const notification_timers = @import("resources/notification_timers.zig");
const plugin_actions = @import("controllers/configuration/plugin_actions.zig");
const presentation_lifecycle = @import("presentation/presentation_lifecycle.zig");
const presenter_mod = @import("presentation/Presenter.zig");
const request_lifecycle_mod = @import("connection/request_lifecycle.zig");
const runtime_transport_mod = @import("telar-client").connection.runtime_transport;
const sidebar_animations = @import("controllers/notifications/sidebar_animations.zig");
const host_output = @import("resources/host_output.zig");

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
    compression_done: *kitty.Compression,
    sidebar_animation_tick: anyerror!void,
    notification_tick: anyerror!void,
    bar_tick: anyerror!void,
    bar_command: bar_updates_controller.Completion,
    sound_played: anyerror!void,
    notified: anyerror!void,
    telemetry_tick: anyerror!void,
    telemetry_written: anyerror!void,
    config_reload: anyerror!config_reload.ConfigReload,
    plugin_result: plugin_actions.Completion,
    clipboard_image: clipboard_images.Completion,
    link_opened: anyerror!void,
};

const client_event_count = @typeInfo(ClientEvent).@"union".fields.len;

const Params = @import("Params.zig");

io: Io,
gpa: std.mem.Allocator,
runtime_transport: runtime_transport_mod.State,
writer: *Io.Writer,
output: ?host_output.Output = null,
select: Io.Select(ClientEvent),
select_storage: [client_event_count]ClientEvent = undefined,
options: Options,
client_identity: schema.ClientIdentity,
telemetry: client_telemetry.State,
client_layouts: client_layout_resource.State = .{},
startup: @import("controllers/session/client_startup.zig").State = .{},
host_negotiation: @import("resources/host_negotiation.zig").State = .{},
presenter: presenter_mod,
view: client_view.State,
model: client_model.Model,
navigation_history: navigation.History = .{},
graphics_store: kitty.Store,
host_input: host_inputs.State,
lua_generation: ?*lua_config.Generation,
plugin_registry: ?*plugin_broker.Registry,
trust_store: ?*core.plugin.TrustStore,
reload: config_reload.State,
sidebar_rendering: kitty.SidebarRendering,
sound_playback: sound_capability.Playback,
notification_delivery: notification_capability.Delivery = .telar,
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
appearance_themes: AppearanceThemes = .{},
clipboard_capture_resources: attachments.CaptureResources = .{},
link_opening: link_capability.Opening = .{},
link_pointer: link_capability.Pointer = .{},

request_lifecycle: request_lifecycle_mod.State = .{},
sidebar_animation_scheduler: sidebar_animations.Scheduler = .{},
notification_scheduler: notification_timers.Scheduler = .{},
bar_updates: bar_updates_controller.State = .{},

const Client = @This();

/// Creates a heap-owned client (the tab models alone are megabytes) and
/// takes ownership of the configuration generation, plugin registry and
/// trust store carried inside `params.options`; `deinit` releases them.
pub fn init(params: Params) !*Client {
    const gpa = params.gpa;
    const client = try gpa.create(Client);
    errdefer gpa.destroy(client);
    var capabilities: client_model.HostCapabilities = .{
        .window_width_px = params.window_width_px,
        .window_height_px = params.window_height_px,
    };
    var host_size = params.host_size;
    const cell_size = capabilities.cellSize(host_size.cols, host_size.rows);
    host_size.cell_width_px = cell_size.width;
    host_size.cell_height_px = cell_size.height;
    try host_size.validate();
    var screen = try term.Screen.init(gpa, host_size.cols, host_size.rows);
    errdefer screen.deinit();
    var view = try client_view.State.initWithAppearance(
        gpa,
        .{ .width = host_size.cols, .height = host_size.rows },
        .{ .theme = params.options.theme, .icons = params.options.icon_theme },
    );
    errdefer view.deinit();
    view.setSidebarLayout(params.options.sidebar_visible, client_view.sidebar_width);
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
    var model = client_model.Model.initWithState(gpa, .{
        .pane_gaps = params.options.pane_gaps,
        .configuration_generation = configuration_generation,
        .bars = params.options.bars,
        .host_size = host_size,
        .host_capabilities = capabilities,
        .sidebar_width = client_view.sidebar_width,
    });
    errdefer model.deinit();
    try model.history_palette.prepare(gpa);
    _ = model.setSidebarVisible(params.options.sidebar_visible);
    var graphics_store = if (params.options.host_shared_memory)
        kitty.Store.initSharedMemory(gpa)
    else
        kitty.Store.init(gpa);
    errdefer graphics_store.deinit();
    var runtime_transport_state = try runtime_transport_mod.State.init(gpa, params.connection);
    errdefer runtime_transport_state.deinit(gpa);
    const host_input = try host_inputs.State.init(params.input_file, .{
        .prefix = params.options.prefix,
        .bindings = params.options.bindings,
        .escape_timeout_ns = params.options.input_escape_timeout_ns,
        .sequence_timeout_ns = params.options.input_sequence_timeout_ns,
    });
    var output: ?host_output.Output = if (params.async_output) try .init(gpa, params.writer) else null;
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
    client.select = Io.Select(ClientEvent).init(params.io, &client.select_storage);
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

fn scheduleCompression(context: *anyopaque, job: *kitty.Compression) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    try client.select.concurrent(.compression_done, kitty.Compression.run, .{job});
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

fn waitForPresentation(io: Io, deadline_ns: u64) anyerror!void {
    const deadline = Io.Timestamp.fromNanoseconds(@intCast(deadline_ns)).withClock(.awake);
    try deadline.wait(io);
}

/// Cancels every in-flight select task first — the reload task publishes
/// into the orphan slots — then releases the orphans, the owned
/// configuration objects, and every buffer.
/// Returns the presentation-supplied region for a synchronous application call.
/// Example: `const region = client.geometry();`.
pub fn geometry(client: *const Client) @import("telar-client").workspace.geometry.Region {
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
