//! Straight-alpha color with 0..1 components, the unit the shader consumes.
const Color = @This();

r: f32,
g: f32,
b: f32,
a: f32 = 1,

pub const white: Color = .{ .r = 1, .g = 1, .b = 1 };
pub const black: Color = .{ .r = 0, .g = 0, .b = 0 };

/// Builds an opaque color from 8-bit components.
/// Example: `const ink = Color.rgb(0xcd, 0xd6, 0xf4);`
pub fn rgb(r: u8, g: u8, b: u8) Color {
    return .{
        .r = @as(f32, @floatFromInt(r)) / 255,
        .g = @as(f32, @floatFromInt(g)) / 255,
        .b = @as(f32, @floatFromInt(b)) / 255,
    };
}
