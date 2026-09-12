const std = @import("std");
const frontend = @import("telar-frontend");
const widgets = @import("../exper_widgets.zig");
const Self = @This();

screen: *frontend.Screen,
writer: *std.Io.Writer,
tty: *frontend.Tty,
last_value: ?i32 = null,

/// Draws changed values or geometry. Example: try render(&terminal, 3);
pub fn render(context: *anyopaque, value: i32) !void {
    const self: *Self = @ptrCast(@alignCast(context));
    const size = self.tty.size();
    const resized = !self.screen.sizeMatches(size.cols, size.rows);
    if (resized) {
        try self.screen.resize(size.cols, size.rows);
    }

    if (!resized and self.last_value == value) {
        return;
    }

    const buffer = self.screen.buffer();
    buffer.clear(.{});
    const rows = buffer.area().splitTop(1);
    const title: widgets.Label = .{ .text = "Frontend experiment | q: quit | + / -: request" };
    title.paint(buffer, rows[0]);
    const counter: widgets.Counter = .{ .value = value };
    counter.paint(buffer, rows[1].inner(1));
    _ = try self.screen.flush(self.writer);
    self.last_value = value;
}
