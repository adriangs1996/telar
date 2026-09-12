//! One line of text to place: UTF-8 bytes, a baseline origin in device pixels
//! and a color.
const Color = @import("../render/Color.zig");

text: []const u8,
x: f32,
y: f32,
color: Color,
