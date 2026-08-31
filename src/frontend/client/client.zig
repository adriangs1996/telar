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
const client_telemetry = @import("telemetry.zig");
const client_view = @import("view.zig");
const client_model = @import("model.zig");
const lua_config = @import("../config/root.zig");
const sound_capability = @import("../sound/root.zig");
const keybind = input_capability.keybind;
const kitty = graphics.kitty;
const toast_graphics = graphics.toast;
const navigation = workspace_capability.navigation;
const term = presentation.screen;
const plugin_broker = @import("../plugins/root.zig");
const ui_capability = @import("../ui/root.zig");
const icons = ui_capability.icons;
const theme = ui_capability.theme;

const Io = std.Io;
const File = Io.File;
const schema = core.schema;

const ConfiguredBinding = lua_config.ConfiguredBinding;
pub const InputRouter = host_inputs.Router;
pub const InputChunk = host_inputs.Chunk;

comptime {
    std.debug.assert(lua_config.max_expression_paste_bytes + 16 <= runtime_transport_mod.max_input_bytes);
}

pub const Options = struct {
    arguments: []const []const u8,
    cwd: []const u8,
    endpoint: []const u8,
    prefix: keybind.Key = keybind.default_prefix,
    bindings: []const ConfiguredBinding = &.{},
    theme: theme.Theme = theme.default_theme,
    icon_theme: icons.Theme = .unicode,
    sidebar_rendering: kitty.SidebarRendering = .automatic,
    sidebar_visible: bool = true,
    pane_gaps: bool = true,
    sound: lua_config.SoundConfig = .{},
    host_shared_memory: bool = false,
    input_escape_timeout_ns: u64 = keybind.default_escape_timeout_ns,
    input_sequence_timeout_ns: u64 = keybind.default_sequence_timeout_ns,
    lua_generation: ?*lua_config.Generation = null,
    config_path: ?[]const u8 = null,
    config_mtime_ns: i128 = 0,
    theme_locked: bool = false,
    sidebar_renderer_locked: bool = false,
    plugin_registry: ?*plugin_broker.Registry = null,
    trust_store: ?*core.plugin.TrustStore = null,
    trust_path: ?[]const u8 = null,
    profile: ?[]const u8 = null,
};

const clipboard_images = @import("clipboard_images.zig");
const config_reload = @import("config_reload.zig");
const host_inputs = @import("host_inputs.zig");
const notification_timers = @import("notification_timers.zig");
const plugin_actions = @import("plugin_actions.zig");
const presenter_mod = @import("presenter.zig");
const request_lifecycle_mod = @import("request_lifecycle.zig");
const runtime_transport_mod = @import("runtime_transport.zig");
const sidebar_animations = @import("sidebar_animations.zig");

pub const ClientEvent = union(enum) {
    input: anyerror!InputChunk,
    input_timeout: anyerror!void,
    binding_timeout: anyerror!void,
    capability_timeout: anyerror!void,
    resized: anyerror!void,
    server: anyerror![]u8,
    sent: anyerror!void,
    draw: anyerror!void,
    media_tick: anyerror!void,
    sidebar_animation_tick: anyerror!void,
    notification_tick: anyerror!void,
    sound_played: anyerror!void,
    telemetry_tick: anyerror!void,
    telemetry_written: anyerror!void,
    config_reload: anyerror!config_reload.ConfigReload,
    plugin_result: plugin_actions.Completion,
    clipboard_image: clipboard_images.Completion,
};

const client_event_count = @typeInfo(ClientEvent).@"union".fields.len;

/// The platform resources a client cannot fabricate: everything else it
/// owns. Substituting these — a pipe for the tty's read handle, a
/// fixed-buffer writer, a scripted socket peer — is what makes the client
/// constructible in a test.
const Params = struct {
    gpa: std.mem.Allocator,
    io: Io,
    connection: *core.transport.SocketChannel,
    input_file: File,
    writer: *Io.Writer,
    /// Host terminal geometry measured by the platform adapter.
    host_size: schema.TerminalSize,
    window_width_px: u32 = 0,
    window_height_px: u32 = 0,
    options: Options,
};

io: Io,
gpa: std.mem.Allocator,
runtime_transport: runtime_transport_mod.State,
writer: *Io.Writer,
select: Io.Select(ClientEvent),
select_storage: [client_event_count]ClientEvent = undefined,
options: Options,
telemetry: client_telemetry.State,
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
clipboard_capture_resources: attachments.CaptureResources = .{},

request_lifecycle: request_lifecycle_mod.State = .{},
sidebar_animation_scheduler: sidebar_animations.Scheduler = .{},
notification_scheduler: notification_timers.Scheduler = .{},

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
        host_size.cols,
        host_size.rows,
        params.options.theme,
        params.options.icon_theme,
    );
    errdefer view.deinit();
    view.setSidebarVisible(params.options.sidebar_visible);
    try view.configureSidebar(
        params.options.sidebar_rendering,
        capabilities.kitty_graphics,
        cell_size.width,
        cell_size.height,
    );
    const configuration_generation = if (params.options.lua_generation) |generation|
        generation.number
    else
        0;
    var model = client_model.Model.initWithState(gpa, .{
        .pane_gaps = params.options.pane_gaps,
        .configuration_generation = configuration_generation,
        .host_size = host_size,
        .host_capabilities = capabilities,
    });
    errdefer model.deinit();
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
    client.* = .{
        .io = params.io,
        .gpa = gpa,
        .runtime_transport = runtime_transport_state,
        .writer = params.writer,
        .select = undefined,
        .options = params.options,
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
            .media = scheduleMedia,
        },
        .metrics = &client.telemetry.metrics,
        .screen = screen,
        .compositor = .init(gpa),
    };
    return client;
}

fn scheduleDraw(context: *anyopaque, deadline_ns: u64) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    try client.select.concurrent(.draw, waitForPresentation, .{ client.io, deadline_ns });
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
pub fn deinit(client: *Client) void {
    const gpa = client.gpa;
    client.select.cancelDiscard();
    client.telemetry.deinit(client.io);
    client.reload.deinit(gpa);
    client.clipboard_capture_resources.deinit(gpa);
    if (client.lua_generation) |generation| generation.deinit();
    if (client.plugin_registry) |registry| gpa.destroy(registry);
    if (client.trust_store) |store| gpa.destroy(store);
    client.graphics_store.deinit();
    client.model.deinit();
    client.view.deinit();
    client.presenter.deinit();
    client.runtime_transport.deinit(gpa);
    gpa.destroy(client);
}
