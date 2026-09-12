const std = @import("std");
const ui = @import("telar-core");

pub const Label = struct {
    text: []const u8,
    style: ui.Style = .{},

    /// Draws one clipped line. Example: label.paint(buffer, area);
    pub fn paint(self: Label, buffer: *ui.Buffer, area: ui.Rect) void {
        _ = buffer.writeText(area, .{
            .point = .{ .x = area.x, .y = area.y },
            .text = self.text,
            .style = self.style,
        });
    }
};

pub const Counter = struct {
    value: i32,

    /// Draws a framed counter without retaining model pointers or allocating.
    /// Example: (Counter{ .value = 3 }).paint(buffer, area);
    pub fn paint(self: Counter, buffer: *ui.Buffer, area: ui.Rect) void {
        buffer.box(area, .{ .title = "Counter", .style = .{} });
        var storage: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&storage, "Value: {d}", .{self.value}) catch unreachable;
        const label: Label = .{ .text = text };
        const inner_area = area.innerCenter(@min(area.w, 20), @min(area.h, 5));
        buffer.box(inner_area, .{ .style = .{} });
        label.paint(buffer, inner_area.innerCenter(@min(inner_area.w, @as(u16, @intCast(text.len))), @min(inner_area.h, 1)));
    }
};

test "counter clips to its area and clears a shorter value when recomposed" {
    var buffer = try ui.Buffer.init(std.testing.allocator, 24, 8);
    defer buffer.deinit();

    buffer.clear(.{});
    const area: ui.Rect = .{ .x = 2, .y = 2, .w = 18, .h = 4 };
    (Counter{ .value = -123 }).paint(&buffer, area);
    try std.testing.expectEqualStrings(" ", buffer.at(0, 0).?.text());
    buffer.clear(.{});
    (Counter{ .value = 1 }).paint(&buffer, area);
    try std.testing.expectEqualStrings("1", buffer.at(14, 3).?.text());
    try std.testing.expectEqualStrings(" ", buffer.at(15, 3).?.text());
    (Counter{ .value = 1 }).paint(&buffer, .{});
}
