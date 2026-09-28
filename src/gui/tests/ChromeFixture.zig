const cellgrid = @import("cellgrid");
const data = @import("model");
const native = @import("../native/native.zig");
const frame_widget = @import("../widgets/frame_widget.zig");
const std = @import("std");
const client = @import("telar-client");
const Session = @import("Session.zig");
const Chrome = @import("../widgets/Chrome.zig");
const Canvas = @import("../widgets/Canvas.zig");
const SidebarBand = @import("../widgets/SidebarBand.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const Fixture = @This();

session: *Session,
chrome: Chrome = .{},

pub fn init() !Fixture {
    const session = try Session.init();
    errdefer session.deinit();
    try session.bootstrap();
    var fixture: Fixture = .{ .session = session };
    try fixture.resize(120, 40);
    return fixture;
}

pub fn deinit(self: *Fixture) void {
    self.session.deinit();
}

/// Sizes the window so the workbench grid holds exactly `cols` by `rows`
/// cells beside the sidebar band the model's visibility and the GUI's
/// preference ask for.
/// Example: `try fixture.resize(120, 40);`
pub fn resize(self: *Fixture, cols: u16, rows: u16) !void {
    const renderer = &self.session.gui.renderer;
    const gui = self.session.gui;
    const reserved = SidebarBand.resolve(gui.sidebar.request(gui.app.model.sidebar_visible), .{ .width = 65535, .cell_width = renderer.metrics.cell_width }).reserved();
    try self.measure(.{ .width = @as(u32, renderer.metrics.cell_width) * cols + reserved, .height = @as(u32, renderer.metrics.cell_height) * rows + renderer.chrome.vertical(), .scale = 1 });
}

/// Measures one exact window through the GUI client and settles the PTY.
/// Example: `try fixture.measure(.{ .width = 800, .height = 600, .scale = 2 });`
pub fn measure(self: *Fixture, viewport: native.Viewport) !void {
    const renderer = &self.session.gui.renderer;
    const gui = self.session.gui;
    const size = try gui.resizeViewport(viewport);
    try gui.resize(size, renderer.theme);
    gui.pointer.configure(renderer.origin, size);
    try self.session.settle();
}

/// Changes the shared visibility and measures the same window again.
/// Example: `try fixture.showSidebar(false);`
pub fn showSidebar(self: *Fixture, visible: bool) !void {
    const renderer = &self.session.gui.renderer;
    _ = data.sidebar.setVisible(&self.session.gui.app.model, visible);
    try self.measure(.{ .width = renderer.viewport[0], .height = renderer.viewport[1], .scale = renderer.scale });
}

pub fn projection(self: *Fixture) client.Projection {
    return client.capture(&self.session.gui.app.model, .{ .geometry = data.workbench.region(&self.session.gui.app.model) });
}

/// The sidebar band of the last painted frame, in device pixels.
/// Example: `const band = fixture.band();`
pub fn band(self: *Fixture) Rect {
    return self.chrome.presented().bands.sidebar;
}

pub fn paint(self: *Fixture, projection_value: client.Projection) !void {
    try self.prepare(projection_value);
    self.chrome.present(true);
}

pub fn prepare(self: *Fixture, projection_value: client.Projection) !void {
    const renderer = &self.session.gui.renderer;
    renderer.quads.clear();
    var canvas: Canvas = .{ .atlas = &renderer.atlas.?, .quads = &renderer.quads, .metrics = renderer.metrics, .origin = renderer.origin, .theme = self.session.gui.app.model.theme, .background_opacity = renderer.config.window.background_opacity, .chrome = renderer.chrome, .viewport = renderer.viewport, .sidebar = renderer.sidebar, .controls = renderer.controls, .sprites = if (renderer.sprites) |*page| page else null };
    self.chrome.animation.begin(self.chrome.now_ns);
    canvas.animation = &self.chrome.animation;
    var context = try self.chrome.begin(&canvas, &projection_value);
    var widgets: frame_widget.List = .{};
    try self.chrome.compose(&context, &widgets);
    try widgets.draw(&canvas);
    self.chrome.seal();
}

pub fn target(self: *Fixture, intent: client.Intent) ?cellgrid.Rect {
    const hits = &self.chrome.presented().hits;
    for (hits.items[0..hits.len]) |hit| {
        if (hit.action == .intent and std.meta.eql(hit.action.intent, intent)) {
            return hit.area;
        }
    }

    return null;
}

/// A delivered band control by identity, in device pixels.
/// Example: `const tab = fixture.bandTarget(.{ .select_tab = id }).?;`
pub fn bandTarget(self: *Fixture, intent: client.Intent) ?Rect {
    const hit = self.chrome.presented().band_hits.find(intent) orelse return null;
    return hit.area;
}

/// Presses and releases a band control at its top-left device pixel.
/// Example: `const command = fixture.clickBand(tab, 0);`
pub fn clickBand(self: *Fixture, area: Rect, button: u32) client.ViewInteractionCommand {
    const command = self.chrome.bandPointer(.{ .kind = .press, .button = @enumFromInt(button), .x = area.x, .y = area.y }) orelse return .{};
    _ = self.chrome.bandPointer(.{ .kind = .release, .button = @enumFromInt(button), .x = area.x, .y = area.y });
    return command.interaction;
}

/// The delivered sidebar resize handle.
/// Example: `const handle = fixture.resizeHandle().?;`
pub fn resizeHandle(self: *Fixture) ?Rect {
    const hits = &self.chrome.presented().band_hits;
    for (hits.items[0..hits.len]) |hit| {
        if (hit.action == .resize_sidebar) {
            return hit.area;
        }
    }

    return null;
}

pub fn click(self: *Fixture, area: cellgrid.Rect, button: u8) client.ViewInteractionCommand {
    const command = self.chrome.pointer(.{ .x = area.x, .y = area.y, .kind = .press, .button = button });
    _ = self.chrome.pointer(.{ .x = area.x, .y = area.y, .kind = .release, .button = button });
    return command;
}
