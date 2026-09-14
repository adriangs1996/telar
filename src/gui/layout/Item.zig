//! A measured child and the rectangle assigned by its parent container.
const Length = @import("length.zig").Length;
const Rect = @import("../render/Rect.zig");

width: Length = .fill,
height: Length = .fill,
intrinsic: [2]f32 = .{ 0, 0 },
minimum: [2]f32 = .{ 0, 0 },
maximum: [2]f32 = .{ 65535, 65535 },
bounds: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
