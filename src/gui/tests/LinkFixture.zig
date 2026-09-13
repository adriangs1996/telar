//! Native gesture fixture whose opener captures targets instead of launching apps.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Session = @import("Session.zig");
const Event = @import("../native/InputEvent.zig").InputEvent;
const Fixture = @This();

session: *Session,
opened: ?client.LinkTarget = null,
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
    session.gui.input.setGeometry(.{ 0, 0 }, session.gui.app.model.hostSize());
    return fixture;
}

pub fn deinit(fixture: *Fixture) void {
    fixture.session.deinit();
    std.testing.allocator.destroy(fixture);
}

pub fn text(fixture: *Fixture, value: []const u8) void {
    const pane = fixture.session.gui.app.model.workspace.findPane(Session.pane_id).?;
    pane.cursor.visible = false;
    pane.buffer.fill(pane.buffer.area(), .{ .glyph = " ", .style = .{} });
    _ = pane.buffer.writeText(pane.buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = value, .style = .{} });
    fixture.session.gui.input.pointer.hover.dirty = true;
}

pub fn present(fixture: *Fixture) !void {
    const gui = fixture.session.gui;
    const token = try gui.prepare(&fixture.session.renderer);
    try gui.complete(token, true);
    try fixture.session.settle();
}

pub fn event(fixture: *Fixture, code: u32) Event {
    const gui = fixture.session.gui;
    const view = gui.app.model.activeTabModel().?.viewForPane(Session.pane_id, gui.region.area).?;
    const size = gui.app.model.hostSize();
    return .{ .kind = 6, .code = code, .mods = @import("../input/hover_target.zig").link_modifier, .x = @as(f64, @floatFromInt(view.content.x + 2)) * size.cell_width_px + 1, .y = @as(f64, @floatFromInt(view.content.y)) * size.cell_height_px + 1 };
}

pub fn send(fixture: *Fixture, value: Event) !void {
    try fixture.session.gui.input.accept(value);
    try fixture.session.gui.inputReady();
    try fixture.session.settle();
}

fn open(context: *anyopaque, target: client.LinkTarget) !void {
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    fixture.opened = target;
    fixture.open_count += 1;
}
