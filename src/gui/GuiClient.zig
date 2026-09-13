//! One native connection's shared model and disposable host resources.
const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const host_ports = @import("host_ports.zig");
const NativeLoop = @import("NativeLoop.zig");
const GuiClient = @This();

app: client.AttachedClient,
driver: *NativeLoop,
input: @import("NativeInput.zig") = .{},
input_revision: u64 = 0,
focused: bool = true,
region: client.Region,
theme: client.ColorTheme,
lifecycle: client.PresentationLifecycleState = .{},
graphics_store: @import("graphics_delivery.zig").Store,

pub fn of(app: *client.AttachedClient) *GuiClient {
    return @fieldParentPtr("app", app);
}

/// Adopts options on success and binds all ports before receiving messages.
/// Example: `const gui = try GuiClient.init(params, &driver);`
pub fn init(params: client.ClientInit, driver: *NativeLoop) !*GuiClient {
    const gui = try params.gpa.create(GuiClient);
    errdefer params.gpa.destroy(gui);
    try client.AttachedClient.init(&gui.app, params);
    // The GUI's absent sidebar uses the existing cells adapter regardless of
    // a shared Lua file's TUI renderer preference, including during reload.
    gui.app.options.sidebar_renderer_locked = true;
    gui.driver = driver;
    driver.configuration.inbox = &driver.inbox;
    gui.input = .{};
    gui.input_revision = 0;
    gui.focused = true;
    gui.theme = params.options.theme;
    gui.region = .{ .area = .{ .w = params.host_size.cols, .h = params.host_size.rows }, .revision = 1 };
    gui.lifecycle = .{};
    gui.graphics_store = .init(params.gpa);
    gui.app.sound_port = host_ports.sound(&gui.app);
    gui.app.notifier = host_ports.notifier(&gui.app);
    gui.app.link_opener = host_ports.links(&gui.app);
    gui.app.capture_port = host_ports.capture(&gui.app);
    gui.app.host_clipboard = host_ports.clipboard(&gui.app);
    gui.app.host_graphics = host_ports.graphics(&gui.app);
    gui.app.graphics = host_ports.graphicsRetention(&gui.app);
    gui.app.chrome = host_ports.chrome(&gui.app);
    gui.app.attachment_catalog = host_ports.attachmentCatalog(&gui.app);
    gui.app.attachment_shelf = host_ports.attachmentShelf(&gui.app);
    gui.app.presentation = host_ports.presentation(&gui.app);
    gui.app.timers = host_ports.timers(&gui.app);
    gui.app.bar_runner = host_ports.barCommands(&gui.app);
    gui.app.plugin_runner = host_ports.pluginWorkers(&gui.app);
    gui.app.clock = host_ports.clock(&gui.app);
    gui.app.host_input_source = host_ports.hostInput(&gui.app);
    gui.app.transport_driver = host_ports.transport(&gui.app);
    gui.app.config_watcher = host_ports.configWatcher(&gui.app);
    return gui;
}

/// Call only after the driver has joined its tasks. Example: `gui.deinit();`
pub fn deinit(gui: *GuiClient) void {
    const gpa = gui.app.gpa;
    if (gui.lifecycle.active) |flight| {
        _ = gui.lifecycle.complete(flight.token, .cancelled);
    }

    gui.graphics_store.deinit();
    gui.app.deinit();
    gpa.destroy(gui);
}

pub fn start(gui: *GuiClient, colors: core.TerminalColors) !void {
    var capabilities = gui.app.model.hostCapabilities();
    capabilities.terminal_colors = colors;
    capabilities.images = .unsupported;
    var handler: client.ResizeHostHandler = .{ .model = &gui.app.model, .effects = .{ .context = gui, .deliver = deliverResize } };
    _ = try handler.execute(.{ .size = gui.app.model.hostSize(), .capabilities = capabilities });
    gui.app.startup.phase = .opening;
    try gui.app.runtime_transport.bootstrap(.{
        .graphics_shared = false,
        .client_identity = gui.app.client_identity,
        .terminal_colors = colors,
    });
    try client.runtime_io.scheduleRead(&gui.app);
    try client.runtime_io.flushGraphicsCredits(&gui.app);
    try client.controllers.config_reloads.schedule(&gui.app);
}

pub fn pump(gui: *GuiClient) !?u8 {
    return gui.driver.drain(gui);
}

/// Applies one validated runtime message before releasing its receive borrow.
/// Example: `const status = try gui.receive(result);`
pub fn receive(gui: *GuiClient, result: anyerror!*const client.RuntimeMessage) !?u8 {
    if (try client.runtime_io.handleRead(&gui.app, result)) |status| {
        return status;
    }

    if (gui.app.startup.phase == .opening and gui.app.model.activeTabLocation() != null) {
        gui.app.startup.phase = .active;
    }

    try gui.resumeInput();
    return null;
}

/// Consumes bounded native input and schedules another turn if it can advance.
/// Example: `try gui.inputReady();`
pub fn inputReady(gui: *GuiClient) !void {
    if (gui.input.len != 0) {
        gui.input_revision +%= 1;
        try gui.input.drain(&gui.app);
        try gui.resumeInput();
    }
}

/// Example: `gui.focus(true);`
pub fn focus(gui: *GuiClient, focused: bool) void {
    gui.focused = focused;
    gui.input_revision +%= 1;
}

/// Queue one readiness notification only when input can make progress.
/// Example: `try gui.resumeInput();`
pub fn resumeInput(gui: *GuiClient) !void {
    if (gui.input.len != 0 and !gui.app.startup.holdsInput() and client.runtime_io.availableCapacity(&gui.app) >= 4) {
        try gui.driver.inbox.notify(.input_ready);
    }
}

/// Copies the visible cursor identity for the native blink clock.
/// Example: `clock.observe(gui.cursorTarget(), now_ns);`
pub fn cursorTarget(gui: *const GuiClient) @import("CursorTarget.zig") {
    const model = gui.app.model.activeTabModelConst() orelse return .{};
    const pane = model.focusedPaneConst() orelse return .{};
    var layout: client.LayoutSnapshot = .{};
    model.layout.snapshot(gui.region.area, &layout);
    for (layout.views()) |view| {
        if (view.pane_id == pane.id and view.surface == .terminal and pane.cursor.x < view.content.w and pane.cursor.y < view.content.h) {
            return .{ .pane_id = pane.id, .generation = pane.attachment_generation, .cursor = pane.cursor };
        }
    }

    return .{};
}

pub fn resizeRegion(gui: *GuiClient, cols: u16, rows: u16) void {
    if (gui.region.area.w == cols and gui.region.area.h == rows) {
        return;
    }

    gui.region = .{ .area = .{ .w = cols, .h = rows }, .revision = gui.region.revision + 1 };
}

/// Publishes exact font metrics and lets shared geometry negotiate the PTY.
/// Example: `try gui.resize(size, renderer.theme);`
pub fn resize(gui: *GuiClient, size: core.TerminalSize, theme: client.TerminalTheme) !void {
    var capabilities = gui.app.model.hostCapabilities();
    capabilities.window_width_px = @as(u32, size.cols) * size.cell_width_px;
    capabilities.window_height_px = @as(u32, size.rows) * size.cell_height_px;
    capabilities.cell_width_px = size.cell_width_px;
    capabilities.cell_height_px = size.cell_height_px;
    capabilities.images = .unsupported;
    capabilities.terminal_colors = .{ .foreground = theme.foreground, .background = theme.background, .palette = theme.palette };
    var handler: client.ResizeHostHandler = .{ .model = &gui.app.model, .effects = .{ .context = gui, .deliver = deliverResize } };
    _ = try handler.execute(.{ .size = size, .capabilities = capabilities });
}

fn deliverResize(context: *anyopaque, commit: client.HostCommit) !void {
    const gui: *GuiClient = @ptrCast(@alignCast(context));
    try client.controllers.host_resources.deliver(&gui.app, commit);
}

/// Retires captured damage after GPU delivery, preserving newer received state.
/// Example: `try gui.complete(token, true);`
pub fn complete(gui: *GuiClient, token: u64, delivered: bool) !void {
    if (token == 0) {
        return;
    }

    const delivery = gui.lifecycle.complete(@enumFromInt(token), if (delivered) .delivered else .failed) orelse return;
    var handler: client.DeliverPresentationHandler = .{
        .model = &gui.app.model,
        .effects = .{ .context = gui, .flush_graphics_credits = flushCredits, .request_media = noMedia },
    };
    try handler.execute(.{ .commit = delivery.commit, .media_pending = delivery.media_pending });
}

fn flushCredits(context: *anyopaque) !void {
    const gui: *GuiClient = @ptrCast(@alignCast(context));
    try client.runtime_io.flushGraphicsCredits(&gui.app);
}

fn noMedia(_: *anyopaque) !void {}

pub fn applyGraphics(gui: *GuiClient, command: client.ApplicationPanesPaneGraphicsCommand) !void {
    return switch (command) {
        .snapshot => |value| gui.graphics_store.applySnapshot(value),
        .image => |value| gui.graphics_store.applyImage(value),
        .shared_image => |value| gui.graphics_store.applySharedImage(value),
        .image_chunk => |value| gui.graphics_store.applyChunk(value),
        .placement => |value| gui.graphics_store.applyPlacement(value),
        .delete_image => |value| gui.graphics_store.deleteImage(value),
        .delete_placement => |value| gui.graphics_store.deletePlacement(value),
    };
}

/// Borrows the projection synchronously and seals only the rendered pane frames.
/// Example: `const token = try gui.prepare(&renderer);`
pub fn prepare(gui: *GuiClient, renderer: *@import("render/TerminalRenderer.zig")) !u64 {
    if (gui.lifecycle.active != null) {
        return error.PresentationBusy;
    }

    const projection = client.capture(&gui.app.model, .{ .geometry = gui.region });
    const observation: client.Observation = .{ .model = projection.version, .geometry_revision = gui.region.revision };
    _ = gui.lifecycle.observe(observation);
    const commit = try renderer.prepare(projection);
    const token = try gui.lifecycle.begin(.{ .observation = observation, .commit = commit, .geometry = client.Geometry.capture(projection) });
    return @intFromEnum(token);
}
