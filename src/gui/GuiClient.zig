//! One native connection's shared model and disposable host resources.
const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const host_ports = @import("host_ports.zig");
const RuntimeDriver = @import("RuntimeDriver.zig");
const GuiClient = @This();

app: client.AttachedClient,
driver: *RuntimeDriver,
input: @import("NativeInput.zig") = .{},
region: client.Region,
theme: client.ColorTheme,
lifecycle: client.PresentationLifecycleState = .{},
graphics_store: @import("graphics_delivery.zig").Store,

pub fn of(app: *client.AttachedClient) *GuiClient {
    return @fieldParentPtr("app", app);
}

/// Adopts options on success and binds all ports before receiving messages.
/// Example: `const gui = try GuiClient.init(params, &driver);`
pub fn init(params: client.ClientInit, driver: *RuntimeDriver) !*GuiClient {
    const gui = try params.gpa.create(GuiClient);
    errdefer params.gpa.destroy(gui);
    try client.AttachedClient.init(&gui.app, params);
    gui.driver = driver;
    gui.input = .{};
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
}

pub fn pump(gui: *GuiClient) !?u8 {
    if (try gui.driver.drain(&gui.app)) |status| {
        return status;
    }

    if (gui.app.startup.phase == .opening and gui.app.model.activeTabLocation() != null) {
        gui.app.startup.phase = .active;
    }

    try gui.input.drain(&gui.app);
    return null;
}

pub fn resizeRegion(gui: *GuiClient, cols: u16, rows: u16) void {
    if (gui.region.area.w == cols and gui.region.area.h == rows) {
        return;
    }

    gui.region = .{ .area = .{ .w = cols, .h = rows }, .revision = gui.region.revision + 1 };
}

/// Publishes exact font metrics and lets shared geometry negotiate the PTY.
/// Example: `try gui.resize(size);`
pub fn resize(gui: *GuiClient, size: core.TerminalSize) !void {
    var capabilities = gui.app.model.hostCapabilities();
    capabilities.window_width_px = @as(u32, size.cols) * size.cell_width_px;
    capabilities.window_height_px = @as(u32, size.rows) * size.cell_height_px;
    capabilities.cell_width_px = size.cell_width_px;
    capabilities.cell_height_px = size.cell_height_px;
    capabilities.images = .unsupported;
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
    const commit = try renderer.prepare(projection, gui.theme);
    const token = try gui.lifecycle.begin(.{ .observation = observation, .commit = commit, .geometry = client.Geometry.capture(projection) });
    return @intFromEnum(token);
}
