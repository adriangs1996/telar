const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const Session = @import("Session.zig");
const Chrome = @import("../widgets/Chrome.zig");
const Canvas = @import("../widgets/Canvas.zig");
const SidebarBand = @import("../widgets/SidebarBand.zig");
const Rect = @import("../render/Rect.zig");
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

pub fn deinit(fixture: *Fixture) void {
    fixture.session.deinit();
}

/// Sizes the window so the workbench grid holds exactly `cols` by `rows`
/// cells beside the sidebar band the model's visibility and the GUI's
/// preference ask for.
/// Example: `try fixture.resize(120, 40);`
pub fn resize(fixture: *Fixture, cols: u16, rows: u16) !void {
    const renderer = &fixture.session.renderer;
    const gui = fixture.session.gui;
    const reserved = SidebarBand.resolve(gui.sidebar.request(gui.app.model.sidebarVisible()), .{ .width = 65535, .cell_width = renderer.metrics.cell_width }).reserved();
    try fixture.measure(.{ .width = @as(u32, renderer.metrics.cell_width) * cols + reserved, .height = @as(u32, renderer.metrics.cell_height) * rows + renderer.chrome.vertical(), .scale = 1 });
}

/// Measures one exact window through the GUI client and settles the PTY.
/// Example: `try fixture.measure(.{ .width = 800, .height = 600, .scale = 2 });`
pub fn measure(fixture: *Fixture, viewport: @import("../native/native.zig").Viewport) !void {
    const renderer = &fixture.session.renderer;
    const gui = fixture.session.gui;
    const size = try gui.measure(renderer, viewport);
    try gui.resize(size, renderer.theme);
    gui.input.setGeometry(renderer.origin, size);
    try fixture.session.settle();
}

/// Changes the shared visibility and measures the same window again.
/// Example: `try fixture.showSidebar(false);`
pub fn showSidebar(fixture: *Fixture, visible: bool) !void {
    const renderer = &fixture.session.renderer;
    _ = fixture.session.gui.app.model.setSidebarVisible(visible);
    try fixture.measure(.{ .width = renderer.viewport[0], .height = renderer.viewport[1], .scale = renderer.scale });
}

pub fn projection(fixture: *Fixture) client.Projection {
    return client.capture(&fixture.session.gui.app.model, .{ .geometry = fixture.session.gui.region });
}

/// The sidebar band of the last painted frame, in device pixels.
/// Example: `const band = fixture.band();`
pub fn band(fixture: *Fixture) Rect {
    return fixture.chrome.presented().bands.sidebar;
}

pub fn paint(fixture: *Fixture, projection_value: client.Projection) !void {
    try fixture.prepare(projection_value);
    fixture.chrome.present(true);
}

pub fn prepare(fixture: *Fixture, projection_value: client.Projection) !void {
    const renderer = &fixture.session.renderer;
    renderer.quads.clear();
    var canvas: Canvas = .{ .atlas = &renderer.atlas.?, .quads = &renderer.quads, .metrics = renderer.metrics, .origin = renderer.origin, .theme = fixture.session.gui.theme, .background_opacity = renderer.config.window.background_opacity, .chrome = renderer.chrome, .viewport = renderer.viewport, .sidebar = renderer.sidebar, .sprites = if (renderer.sprites) |*page| page else null };
    fixture.chrome.animation.begin(fixture.chrome.now_ns);
    canvas.animation = &fixture.chrome.animation;
    var context = try fixture.chrome.begin(&canvas, &projection_value);
    var widgets: @import("../widgets/frame_widget.zig").List = .{};
    try fixture.chrome.compose(&context, &widgets);
    try widgets.draw(&canvas);
    fixture.chrome.seal();
}

pub fn target(fixture: *Fixture, intent: client.Intent) ?core.Rect {
    const hits = &fixture.chrome.presented().hits;
    for (hits.items[0..hits.len]) |hit| {
        if (hit.action == .intent and std.meta.eql(hit.action.intent, intent)) {
            return hit.area;
        }
    }

    return null;
}

/// A delivered band control by identity, in device pixels.
/// Example: `const tab = fixture.bandTarget(.{ .select_tab = id }).?;`
pub fn bandTarget(fixture: *Fixture, intent: client.Intent) ?Rect {
    const hit = fixture.chrome.presented().band_hits.find(intent) orelse return null;
    return hit.area;
}

/// Presses and releases a band control at its top-left device pixel.
/// Example: `const command = fixture.clickBand(tab, 0);`
pub fn clickBand(fixture: *Fixture, area: Rect, button: u32) client.ViewInteractionCommand {
    const command = fixture.chrome.bandPointer(.{ .kind = .press, .button = @enumFromInt(button), .x = area.x, .y = area.y }) orelse return .{};
    _ = fixture.chrome.bandPointer(.{ .kind = .release, .button = @enumFromInt(button), .x = area.x, .y = area.y });
    return command.interaction;
}

/// The delivered sidebar resize handle.
/// Example: `const handle = fixture.resizeHandle().?;`
pub fn resizeHandle(fixture: *Fixture) ?Rect {
    const hits = &fixture.chrome.presented().band_hits;
    for (hits.items[0..hits.len]) |hit| {
        if (hit.action == .resize_sidebar) {
            return hit.area;
        }
    }

    return null;
}

pub fn click(fixture: *Fixture, area: core.Rect, button: u8) client.ViewInteractionCommand {
    const command = fixture.chrome.pointer(.{ .x = area.x, .y = area.y, .kind = .press, .button = button });
    _ = fixture.chrome.pointer(.{ .x = area.x, .y = area.y, .kind = .release, .button = button });
    return command;
}
