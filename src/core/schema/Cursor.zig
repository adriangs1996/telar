const std = @import("std");
const CursorAppearance = @import("CursorAppearance.zig");
pub const Shape = CursorAppearance.Shape;

visible: bool = false,
x: u16 = 0,
y: u16 = 0,
appearance: CursorAppearance.CursorAppearance = .{},

test "cursor metadata uses the existing padding in bounded client models" {
    try std.testing.expectEqual(@as(usize, 6), @sizeOf(@This()));
}
