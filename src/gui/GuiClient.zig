//! One native connection's shared model and disposable host resources.
const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const host_ports = @import("host_ports.zig");
const NativeLoop = @import("NativeLoop.zig");
const NativeInput = @import("NativeInput.zig");
const Regions = @import("chrome/Regions.zig");
const selection = @import("render/copy_selection.zig");
const GuiClient = @This();

app: client.AttachedClient,
driver: *NativeLoop,
input: NativeInput = .{},
input_revision: u64 = 0,
focused: bool = true,
region: client.Region,
theme: client.ColorTheme,
chrome: @import("chrome/Chrome.zig") = .{},
overlays: @import("overlays/Overlays.zig") = .{},
lifecycle: client.PresentationLifecycleState = .{},
graphics_store: @import("graphics_delivery.zig").Store,

pub fn of(app: *client.AttachedClient) *GuiClient {
    return @fieldParentPtr("app", app);
}

/// Adopts options on success and binds all ports before receiving messages.
/// Example: `const gui = try GuiClient.init(params, &driver);`
pub fn init(params: client.ClientInit, driver: *NativeLoop) !*GuiClient {
    const input = try NativeInput.init(.{ .prefix = params.options.prefix, .bindings = params.options.bindings, .escape_timeout_ns = params.options.input_escape_timeout_ns, .sequence_timeout_ns = params.options.input_sequence_timeout_ns });
    const gui = try params.gpa.create(GuiClient);
    errdefer params.gpa.destroy(gui);
    try client.AttachedClient.init(&gui.app, params);
    // Native chrome uses the shared semantic projection, never TUI Kitty output.
    gui.app.options.sidebar_renderer_locked = true;
    gui.driver = driver;
    driver.configuration.inbox = &driver.inbox;
    gui.input = input;
    gui.input_revision = 0;
    gui.focused = true;
    gui.theme = params.options.theme;
    gui.region = .{ .area = .{}, .revision = 0 };
    gui.resizeRegion(params.host_size.cols, params.host_size.rows);
    gui.chrome = .{};
    gui.overlays = .{ .router = &gui.input.router };
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
    gui.app.path_completion_runner = host_ports.pathCompletions(&gui.app);
    gui.app.favicon_runner = host_ports.favicons(&gui.app);
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
    gui.chrome.favicons.deinit(gpa);
    gui.app.deinit();
    gpa.destroy(gui);
}

pub fn start(gui: *GuiClient, colors: core.TerminalColors) !void {
    var capabilities = gui.app.model.hostCapabilities();
    capabilities.terminal_colors = colors;
    capabilities.images = .unsupported;
    capabilities.pointer_pixels = .supported;
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
    try client.controllers.bar_updates.synchronize(&gui.app);
}

pub fn pump(gui: *GuiClient) !?u8 {
    const status = try gui.driver.drain(gui);
    gui.refreshPointer();
    return status;
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
    gui.refreshPointer();
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

/// Example: `try gui.focus(true);`
pub fn focus(gui: *GuiClient, focused: bool) !void {
    gui.focused = focused;
    gui.input_revision +%= 1;
    if (!focused) {
        gui.input.pointer.hover.clear();
        gui.input.pointer.link_gesture.cancel();
        gui.chrome.cancelPointer();
        gui.overlays.cancelPointer();
        try gui.input.cancelPointer(&gui.app);
    }
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
    if (gui.app.model.name_prompt.active()) {
        return .{};
    }

    const model = gui.app.model.activeTabModelConst() orelse return .{};
    const pane = model.focusedPaneConst() orelse return .{};
    const copy = gui.app.model.copyModeProjection();
    const copy_view: ?client.CopyModeView = if (copy) |value| if (value.pane_id == pane.id) value.view else null else null;
    const cursor = selection.cursor(pane, copy_view);
    var layout: client.LayoutSnapshot = .{};
    model.layout.snapshot(gui.region.area, &layout);
    for (layout.views()) |view| {
        if (view.pane_id == pane.id and view.surface == .terminal and cursor.x < view.content.w and cursor.y < view.content.h) {
            return .{ .pane_id = pane.id, .generation = pane.attachment_generation, .cursor = cursor };
        }
    }

    return .{};
}

pub fn resizeRegion(gui: *GuiClient, cols: u16, rows: u16) void {
    const regions = Regions.calculate(cols, rows, .{ .visible = gui.app.model.sidebarVisible(), .preferred_width = gui.app.model.sidebarWidth() });
    if (std.meta.eql(gui.region.area, regions.workbench)) {
        return;
    }

    gui.region = .{ .area = regions.workbench, .revision = gui.region.revision + 1 };
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
    capabilities.pointer_pixels = .supported;
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
    const active = gui.lifecycle.active orelse return;
    if (token == 0 or token != @intFromEnum(active.token)) {
        return;
    }

    gui.chrome.present(delivered);
    gui.overlays.present(delivered);
    gui.input.pointer.hover.present(delivered);
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

    gui.refreshPointer();
    gui.chrome.now_s = @intCast(client.monotonic(gui.app.io) / std.time.ns_per_s);
    try gui.resolveFavicons(renderer);
    const projected = gui.projection();
    const observed = gui.observation();
    _ = gui.lifecycle.observe(observed);
    var scene: @import("render/Scene.zig") = .{ .terminal = renderer, .chrome = &gui.chrome, .overlays = &gui.overlays, .theme = gui.theme, .link = if (gui.input.pointer.hover.link) |*hit| hit else null };
    const commit = try scene.prepare(projected);
    const token = try gui.lifecycle.begin(.{ .observation = observed, .commit = commit, .geometry = client.Geometry.capture(projected) });
    gui.input.pointer.hover.prepare();
    return @intFromEnum(token);
}

/// Lands one favicon lookup from the inbox; the next preparation places it.
/// Example: `gui.landFavicon(completion);`
pub fn landFavicon(gui: *GuiClient, completion: client.FaviconCompletion) void {
    const image: ?*client.FaviconImage = switch (client.controllers.favicons.complete(&gui.app, completion)) {
        .stale => return,
        .missing => null,
        .image => |owned| owned,
    };
    gui.chrome.favicons.land(gui.app.gpa, .{ .workspace = completion.workspace, .image = image });
    gui.chrome.invalidate();
}

// Places a landed favicon into the page and starts the next lookup the
// list needs. Warm frames find nothing landed and nothing wanted.
fn resolveFavicons(gui: *GuiClient, renderer: *@import("render/TerminalRenderer.zig")) !void {
    const page = if (renderer.sprites) |*sprites| sprites else return;
    const favicons = &gui.chrome.favicons;
    favicons.refresh(gui.app.gpa, page);
    const want = favicons.next(gui.app.model.workspaceListSnapshot()) orelse return;
    if (try client.controllers.favicons.request(&gui.app, .{ .workspace = want.workspace, .cwd = want.cwd, .cell = @intCast(page.cell) })) {
        favicons.started(want.workspace);
    }
}

fn refreshPointer(gui: *GuiClient) void {
    gui.input.pointer.hover.refresh(gui);
    gui.input.pointer.link_gesture.validate(gui.input.pointer.hover.link, gui.app.model.version());
}

/// Captures semantic state plus adapter-owned routing and interaction revisions.
/// Example: `const projected = gui.projection();`
pub fn projection(gui: *const GuiClient) client.Projection {
    return client.capture(&gui.app.model, .{ .geometry = gui.region, .status_mode = gui.input.statusMode(gui.app.model.copyModeActive()), .presentation_ingress = gui.ingress() });
}

/// Example: `_ = gui.lifecycle.observe(gui.observation());`
pub fn observation(gui: *const GuiClient) client.Observation {
    return .{ .model = gui.app.model.version(), .geometry_revision = gui.region.revision, .presentation_ingress = gui.ingress() };
}

fn ingress(gui: *const GuiClient) client.PresentationIngress {
    return .{ .input_routing = gui.input.presentation_revision, .view_interaction = gui.chrome.revision +% gui.input.pointer.hover.revision };
}
