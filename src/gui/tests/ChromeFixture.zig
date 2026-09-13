const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const Session = @import("Session.zig");
const Chrome = @import("../chrome/Chrome.zig");
const Canvas = @import("../chrome/Canvas.zig");
const Regions = @import("../chrome/Regions.zig");
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

pub fn resize(fixture: *Fixture, cols: u16, rows: u16) !void {
    const renderer = &fixture.session.renderer;
    const size = try renderer.measure(.{ .width = @as(u32, renderer.metrics.cell_width) * cols, .height = @as(u32, renderer.metrics.cell_height) * rows, .scale = 1 });
    try fixture.session.gui.resize(size, renderer.theme);
    try fixture.session.settle();
}

pub fn projection(fixture: *Fixture) client.Projection {
    var value = client.capture(&fixture.session.gui.app.model, .{ .geometry = fixture.session.gui.region });
    value.geometry.area = Regions.calculate(value.host_size.cols, value.host_size.rows, .{ .visible = value.sidebar_visible, .preferred_width = value.sidebar_width }).workbench;
    return value;
}

pub fn paint(fixture: *Fixture, projection_value: client.Projection) !void {
    try fixture.prepare(projection_value);
    fixture.chrome.present(true);
}

pub fn prepare(fixture: *Fixture, projection_value: client.Projection) !void {
    const renderer = &fixture.session.renderer;
    renderer.quads.clear();
    var canvas: Canvas = .{ .atlas = &renderer.atlas.?, .quads = &renderer.quads, .metrics = renderer.metrics, .origin = renderer.origin, .theme = fixture.session.gui.theme };
    try fixture.chrome.paint(&canvas, projection_value);
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

pub fn click(fixture: *Fixture, area: core.Rect, button: u8) client.ViewInteractionCommand {
    const command = fixture.chrome.pointer(.{ .x = area.x, .y = area.y, .kind = .press, .button = button });
    _ = fixture.chrome.pointer(.{ .x = area.x, .y = area.y, .kind = .release, .button = button });
    return command;
}
