//! Native gesture fixture whose opener captures targets instead of launching apps.
const hover_target = @import("../input/hover_target.zig");
const data = @import("model");
const input_support = @import("input_support.zig");
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Session = @import("Session.zig");
const Event = @import("../native/InputEvent.zig").InputEvent;
const Fixture = @This();

session: *Session,
opened: ?data.LinkTarget = null,
open_count: usize = 0,

pub fn init() !*Fixture {
    const fixture = try std.testing.allocator.create(Fixture);
    errdefer std.testing.allocator.destroy(fixture);
    fixture.* = .{ .session = try Session.init() };
    errdefer fixture.session.deinit();
    const session = fixture.session;
    try session.bootstrap();
    try session.receiveFrame(1);
    fixture.text("https://a.b");
    session.gui.app.link_opener = .{ .context = fixture, .open = open };
    try fixture.present();
    session.gui.pointer.configure(session.gui.renderer.origin, session.gui.app.model.hostSize());
    return fixture;
}

pub fn deinit(fixture: *Fixture) void {
    fixture.session.deinit();
    std.testing.allocator.destroy(fixture);
}

pub fn text(fixture: *Fixture, value: []const u8) void {
    const pane = fixture.session.gui.app.model.panes.find(Session.pane_id).?;
    pane.cursor.visible = false;
    pane.buffer.fill(pane.buffer.area(), .{ .glyph = " ", .style = .{} });
    _ = pane.buffer.writeText(pane.buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = value, .style = .{} });
    pane.markSpan(0, @intCast(pane.buffer.cells.len));
    fixture.session.gui.pointer.hover.dirty = true;
}

pub fn present(fixture: *Fixture) !void {
    const gui = fixture.session.gui;
    const token = try fixture.session.draw();
    try input_support.presented(
        gui,
        token,
        true,
    );
    try fixture.session.settle();
}

pub fn event(fixture: *Fixture, code: u32) Event {
    const gui = fixture.session.gui;
    const view = data.tab_layout.view(&gui.app.model, gui.app.model.tabs.active, Session.pane_id, gui.region.area).?;
    const size = gui.app.model.hostSize();
    return .{
        .kind = 6,
        .code = code,
        .mods = hover_target.link_modifier,
        .x = @as(f64, @floatFromInt(view.content.x + 2)) * size.cell_width_px + @as(f64, @floatFromInt(fixture.session.gui.renderer.origin[0])) + 1,
        .y = @as(f64, @floatFromInt(view.content.y)) * size.cell_height_px + @as(f64, @floatFromInt(fixture.session.gui.renderer.origin[1])) + 1,
    };
}

pub fn send(fixture: *Fixture, value: Event) !void {
    try input_support.acceptNative(fixture.session.gui, value);
    try input_support.pump(fixture.session.gui);
    try fixture.session.settle();
}

fn open(context: *anyopaque, target: data.LinkTarget) !void {
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    fixture.opened = target;
    fixture.open_count += 1;
}
