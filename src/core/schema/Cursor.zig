pub const Shape = @import("CursorAppearance.zig").Shape;

visible: bool = false,
x: u16 = 0,
y: u16 = 0,
appearance: @import("CursorAppearance.zig").CursorAppearance = .{},

test "cursor metadata uses the existing padding in bounded client models" {
    try @import("std").testing.expectEqual(@as(usize, 6), @sizeOf(@This()));
}
