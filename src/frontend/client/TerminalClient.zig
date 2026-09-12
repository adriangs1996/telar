//! The TUI's client: the shared `AttachedClient` plus the terminal resources
//! that only make sense while somebody is looking. `init` builds the shared
//! state in place, then binds every host port to this heap-stable value.

const std = @import("std");
const AttachedClient = @import("telar-client").AttachedClient;
const OptionsType = @import("telar-client").Options;
const Params = @import("Params.zig");
const CompressionType = @import("../graphics/Compression.zig");
const BarUpdatesCompletion = @import("telar-client").BarUpdatesCompletion;
const PluginActionsCompletion = @import("telar-client").PluginActionsCompletion;
const ConfigReloadType = @import("telar-client").ConfigReload;
const CompletionType = @import("telar-client").controllers.ClipboardImageCompletion;
const OutputType = @import("resources/Output.zig");
const HostNegotiationState = @import("resources/HostNegotiationState.zig");
const Presenter = @import("presentation/Presenter.zig");
const PresentationState = @import("presentation/State.zig");
const ScreenType = @import("../presentation/Screen.zig");
const kitty_delivery = @import("../graphics/kitty_delivery.zig");
const InputState = @import("controllers/input/State.zig");
const host_inputs = @import("controllers/input/host_inputs.zig");
const SidebarRenderingType = @import("telar-client").SidebarRendering;
const default_width = @import("telar-client").default_width;
const host_ports = @import("resources/host_ports.zig");
const presentation_lifecycle = @import("presentation/presentation_lifecycle.zig");

pub const InputRouter = host_inputs.Router;
pub const InputChunk = @import("controllers/input/Chunk.zig");
pub const Options = OptionsType;
pub const AppearanceThemes = @import("telar-client").AppearanceThemes;

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
    config_reload: anyerror!ConfigReloadType,
    plugin_result: PluginActionsCompletion,
    clipboard_image: CompletionType,
    link_opened: anyerror!void,
};

const client_event_count = @typeInfo(ClientEvent).@"union".fields.len;

const TerminalClient = @This();

app: AttachedClient,
writer: *std.Io.Writer,
output: ?OutputType = null,
select: std.Io.Select(ClientEvent),
select_storage: [client_event_count]ClientEvent = undefined,
host_negotiation: HostNegotiationState = .{},
presenter: Presenter,
view: PresentationState,
graphics_store: kitty_delivery.Store,
host_input: InputState,
sidebar_rendering: SidebarRenderingType,

/// Recovers the terminal client that embeds one shared client. Every host
/// port and every terminal-side handler receives the shared client and
/// climbs back here for terminal resources.
///
/// ```zig
/// const terminal = TerminalClient.of(client);
/// ```
pub fn of(client: *AttachedClient) *TerminalClient {
    return @fieldParentPtr("app", client);
}

/// Read-only variant of `of`. Example: `const terminal = TerminalClient.ofConst(client);`.
pub fn ofConst(client: *const AttachedClient) *const TerminalClient {
    return @fieldParentPtr("app", client);
}

/// Creates a heap-owned client (the tab models alone are megabytes) and
/// takes ownership of the configuration generation, plugin registry and
/// trust store carried inside `params.options`; `deinit` releases them.
pub fn init(params: Params) !*TerminalClient {
    const gpa = params.gpa;
    const terminal = try gpa.create(TerminalClient);
    errdefer gpa.destroy(terminal);
    try AttachedClient.init(&terminal.app, .{
        .gpa = gpa,
        .io = params.io,
        .connection = params.connection,
        .host_size = params.host_size,
        .window_width_px = params.window_width_px,
        .window_height_px = params.window_height_px,
        .client_identity = params.client_identity,
        .options = params.options,
    });
    errdefer terminal.app.deinit();
    const host_size = terminal.app.model.hostSize();
    const capabilities = terminal.app.model.hostCapabilities();
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
            .cell_width = host_size.cell_width_px,
            .cell_height = host_size.cell_height_px,
        },
    );
    var graphics_store = if (params.options.host_shared_memory)
        kitty_delivery.Store.initSharedMemory(gpa)
    else
        kitty_delivery.Store.init(gpa);
    errdefer graphics_store.deinit();
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

    terminal.writer = params.writer;
    terminal.output = output;
    terminal.select = undefined;
    terminal.host_negotiation = .{};
    terminal.presenter = undefined;
    terminal.view = view;
    terminal.graphics_store = graphics_store;
    terminal.host_input = host_input;
    terminal.sidebar_rendering = params.options.sidebar_rendering;
    if (terminal.output) |*value| {
        terminal.writer = &value.writer;
        terminal.graphics_store.delivery.compression_scheduler = .{ .context = terminal, .start = scheduleCompression };
    }

    // The select's storage lives inside the heap-stable client, so the
    // select can only be built once the client's address exists.
    terminal.select = std.Io.Select(ClientEvent).init(params.io, &terminal.select_storage);
    const client = &terminal.app;
    client.sound_port = host_ports.sound(client);
    client.notifier = host_ports.notifier(client);
    client.link_opener = host_ports.links(client);
    client.capture_port = host_ports.capture(client);
    client.host_clipboard = host_ports.clipboard(client);
    client.host_graphics = host_ports.graphics(client);
    client.graphics = host_ports.graphicsRetention(client);
    client.chrome = host_ports.chrome(client);
    client.attachment_catalog = host_ports.attachmentCatalog(client);
    client.attachment_shelf = host_ports.attachmentShelf(client);
    client.presentation = host_ports.presentation(client);
    client.timers = host_ports.timers(client);
    client.bar_runner = host_ports.barCommands(client);
    client.plugin_runner = host_ports.pluginWorkers(client);
    client.clock = host_ports.clock(client);
    client.host_input_source = host_ports.hostInput(client);
    client.transport_driver = host_ports.transport(client);
    client.config_watcher = host_ports.configWatcher(client);
    // The presenter borrows the select and metrics, whose heap addresses
    // only exist once the client does.
    terminal.presenter = .{
        .io = params.io,
        .scheduler = .{
            .context = terminal,
            .draw = scheduleDraw,
            .draw_now = drawNow,
            .media = scheduleMedia,
        },
        .metrics = &terminal.app.telemetry.metrics,
        .screen = screen,
        .compositor = .init(gpa),
    };
    return terminal;
}

fn scheduleCompression(context: *anyopaque, job: *CompressionType) !void {
    const terminal: *TerminalClient = @ptrCast(@alignCast(context));
    try terminal.select.concurrent(.compression_done, CompressionType.run, .{job});
}

fn scheduleDraw(context: *anyopaque, deadline_ns: u64) !void {
    const terminal: *TerminalClient = @ptrCast(@alignCast(context));
    try terminal.select.concurrent(.draw, waitForPresentation, .{ terminal.app.io, deadline_ns });
}

fn drawNow(context: *anyopaque) !void {
    const terminal: *TerminalClient = @ptrCast(@alignCast(context));
    try presentation_lifecycle.presentNow(&terminal.app);
}

fn scheduleMedia(context: *anyopaque, deadline_ns: u64) !void {
    const terminal: *TerminalClient = @ptrCast(@alignCast(context));
    try terminal.select.concurrent(.media_tick, waitForPresentation, .{ terminal.app.io, deadline_ns });
}

fn waitForPresentation(io: std.Io, deadline_ns: u64) anyerror!void {
    const deadline = std.Io.Timestamp.fromNanoseconds(@intCast(deadline_ns)).withClock(.awake);
    try deadline.wait(io);
}

/// Cancels every in-flight select task first — the reload task publishes
/// into the orphan slots — then releases terminal resources, the shared
/// state and finally the allocation.
pub fn deinit(terminal: *TerminalClient) void {
    const gpa = terminal.app.gpa;
    terminal.select.cancelDiscard();
    if (terminal.output) |*output| {
        output.deinit();
    }

    terminal.graphics_store.deinit();
    terminal.view.deinit();
    terminal.presenter.deinit();
    terminal.app.deinit();
    gpa.destroy(terminal);
}
