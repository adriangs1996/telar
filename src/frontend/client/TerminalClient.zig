//! The TUI's client: the shared `AttachedClient` plus the terminal resources
//! that only make sense while somebody is looking. `init` builds the shared
//! state in place, then binds every host port to this heap-stable value.

const client_module = @import("telar-client");
const core = @import("telar-core");
const data = @import("model");
const std = @import("std");
const Params = @import("Params.zig");
const Compression = @import("../graphics/Compression.zig");
const Output = @import("resources/Output.zig");
const HostNegotiationState = @import("resources/HostNegotiationState.zig");
const Presenter = @import("presentation/Presenter.zig");
const PresentationState = @import("presentation/State.zig");
const Screen = @import("../presentation/Screen.zig");
const kitty_delivery = @import("../graphics/kitty_delivery.zig");
const InputState = @import("controllers/input/State.zig");
const host_inputs = @import("controllers/input/host_inputs.zig");
const host_ports = @import("resources/host_ports.zig");
const view_chrome = @import("presentation/view_chrome.zig");
const ChromeRevisions = @import("presentation/ChromeRevisions.zig");
const capture_module = @import("../attachments/capture.zig");
const presentation_lifecycle = @import("presentation/presentation_lifecycle.zig");

pub const InputRouter = host_inputs.Router;
pub const Options = client_module.Options;
pub const AppearanceThemes = data.AppearanceThemes;

pub const ClientEvent = union(enum) {
    /// Bytes read into `host_input.chunk`; zero is EOF.
    input: anyerror!u16,
    input_timeout: anyerror!void,
    binding_timeout: anyerror!void,
    capability_timeout: anyerror!void,
    resized: anyerror!void,
    /// An event the shared client handles itself.
    client: client_module.Message,
    draw: anyerror!void,
    media_tick: anyerror!void,
    host_written: anyerror!void,
    compression_done: *Compression,
    telemetry_tick: anyerror!void,
    telemetry_written: anyerror!void,
    clipboard_image: client_module.operations.ClipboardImageCompletion,
};

const TerminalClient = @This();

app: client_module.AttachedClient,
writer: *std.Io.Writer,
output: ?Output = null,
inbox: client_module.GenericInbox(ClientEvent),
host_negotiation: HostNegotiationState = .{},
presenter: Presenter,
view: PresentationState,
graphics_store: kitty_delivery.Store,
host_input: InputState,
chrome_observed: ChromeRevisions = .{},

/// Creates a heap-owned client (the tab models alone are megabytes) and
/// takes ownership of the configuration generation, plugin registry and
/// trust store carried inside `params.options`; `deinit` releases them.
pub fn init(params: Params) !*TerminalClient {
    const gpa = params.gpa;
    const terminal = try gpa.create(TerminalClient);
    errdefer gpa.destroy(terminal);
    try client_module.AttachedClient.init(&terminal.app, .{
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
    const host_size = terminal.app.model.host.host_size;
    var screen = try Screen.init(gpa, host_size.cols, host_size.rows);
    errdefer screen.deinit();
    var view = try PresentationState.initWithAppearance(
        gpa,
        .{ .width = host_size.cols, .height = host_size.rows },
        .{ .theme = terminal.app.model.theme, .icons = terminal.app.model.icon_theme },
    );
    errdefer view.deinit();
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
    var output: ?Output = if (params.async_output) try .init(gpa, params.writer) else null;
    if (output) |*value| {
        value.fast_write = params.fast_output;
    }
    errdefer if (output) |*value| {
        value.deinit();
    };

    terminal.writer = params.writer;
    terminal.output = output;
    terminal.inbox = .init(params.io, .{});
    terminal.host_negotiation = .{};
    terminal.presenter = undefined;
    terminal.view = view;
    terminal.graphics_store = graphics_store;
    terminal.host_input = host_input;
    terminal.chrome_observed = .{};
    if (terminal.output) |*value| {
        terminal.writer = &value.writer;
        terminal.graphics_store.delivery.compression_scheduler = .{ .context = terminal, .start = scheduleCompression };
    }

    const client = &terminal.app;
    client.model.host.clipboard_capture = capture_module.platformSupported();
    client.model.host.grid_chrome = true;
    client.model.host.animation_frame_ns = core.pace.default_interval;
    client.graphics = host_ports.graphicsRetention(terminal);
    client.chrome = host_ports.chrome(terminal);
    client.attachments = host_ports.attachmentShelf(terminal);
    client.workers = host_ports.workers(terminal);
    client.host_input_source = host_ports.hostInput(terminal);
    // The presenter borrows the inbox and metrics, whose heap addresses
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
        .presentation_state = &terminal.app.presentation,
        .screen = screen,
        .compositor = .init(gpa),
    };
    try view_chrome.refresh(terminal);

    return terminal;
}

fn scheduleCompression(context: *anyopaque, job: *Compression) !void {
    const terminal: *TerminalClient = @ptrCast(@alignCast(context));
    try terminal.inbox.start(.compression_done, .{ Compression.run, .{job} });
}

fn scheduleDraw(context: *anyopaque, deadline_ns: u64) !void {
    const terminal: *TerminalClient = @ptrCast(@alignCast(context));
    try terminal.inbox.start(.draw, .{ waitForPresentation, .{ terminal.app.io, deadline_ns } });
}

fn drawNow(context: *anyopaque) !void {
    const terminal: *TerminalClient = @ptrCast(@alignCast(context));
    try presentation_lifecycle.presentNow(terminal);
}

fn scheduleMedia(context: *anyopaque, deadline_ns: u64) !void {
    const terminal: *TerminalClient = @ptrCast(@alignCast(context));
    try terminal.inbox.start(.media_tick, .{ waitForPresentation, .{ terminal.app.io, deadline_ns } });
}

fn waitForPresentation(io: std.Io, deadline_ns: u64) anyerror!void {
    const deadline = std.Io.Timestamp.fromNanoseconds(@intCast(deadline_ns)).withClock(.awake);
    try deadline.wait(io);
}

/// Cancels every admitted producer first — the reload task publishes
/// into the orphan slots — then releases terminal resources, the shared
/// state and finally the allocation.
pub fn deinit(terminal: *TerminalClient) void {
    const gpa = terminal.app.gpa;
    terminal.inbox.deinit();
    if (terminal.output) |*output| {
        output.deinit();
    }

    terminal.graphics_store.deinit();
    terminal.view.deinit();
    terminal.presenter.deinit();
    terminal.app.deinit();
    gpa.destroy(terminal);
}
