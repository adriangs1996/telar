//! A measured child and the rectangle assigned by its parent container.
const length = @import("length.zig");
const Rect = @import("Rect.zig");

width: length.Length = .fill,
height: length.Length = .fill,
intrinsic: [2]f32 = .{ 0, 0 },
minimum: [2]f32 = .{ 0, 0 },
maximum: [2]f32 = .{ 65535, 65535 },
bounds: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
