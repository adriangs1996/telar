//! Native gesture fixture whose opener captures targets instead of launching apps.
const hover_target = @import("../input/hover_target.zig");
const data = @import("model");
const input_support = @import("input_support.zig");
const std = @import("std");
const Session = @import("Session.zig");
const Event = @import("../native/InputEvent.zig").InputEvent;
const Fixture = @This();

session: *Session,

pub fn init() !*Fixture {
    const fixture = try std.testing.allocator.create(Fixture);
    errdefer std.testing.allocator.destroy(fixture);
    fixture.* = .{ .session = try Session.init() };
    errdefer fixture.session.deinit();
    const session = fixture.session;
    try session.bootstrap();
    try session.receiveFrame(1);
    fixture.text("https://a.b");
    try fixture.present();
    session.gui.pointer.configure(session.gui.renderer.origin, session.gui.app.model.host.host_size);
    return fixture;
}

pub fn deinit(self: *Fixture) void {
    self.session.deinit();
    std.testing.allocator.destroy(self);
}

pub fn text(self: *Fixture, value: []const u8) void {
    const pane = self.session.gui.app.model.panes.find(Session.pane_id).?;
    pane.cursor.visible = false;
    pane.buffer.fill(pane.buffer.area(), .{ .glyph = " ", .style = .{} });
    _ = pane.buffer.writeText(pane.buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = value, .style = .{} });
    pane.markSpan(0, @intCast(pane.buffer.cells.len));
    self.session.gui.pointer.hover.dirty = true;
}

pub fn present(self: *Fixture) !void {
    const gui = self.session.gui;
    const token = try self.session.draw();
    try input_support.presented(
        gui,
        token,
        true,
    );
    try self.session.settle();
}

pub fn event(self: *Fixture, code: u32) Event {
    const gui = self.session.gui;
    const view = data.tab_layout.view(&gui.app.model, gui.app.model.tabs.active, Session.pane_id, data.workbench.region(&gui.app.model).area).?;
    const size = gui.app.model.host.host_size;
    return .{
        .kind = 6,
        .code = code,
        .mods = hover_target.link_modifier,
        .x = @as(f64, @floatFromInt(view.content.x + 2)) * size.cell_width_px + @as(f64, @floatFromInt(self.session.gui.renderer.origin[0])) + 1,
        .y = @as(f64, @floatFromInt(view.content.y)) * size.cell_height_px + @as(f64, @floatFromInt(self.session.gui.renderer.origin[1])) + 1,
    };
}

pub fn send(self: *Fixture, value: Event) !void {
    try input_support.acceptNative(self.session.gui, value);
    try input_support.pump(self.session.gui);
    try self.session.settle();
}
