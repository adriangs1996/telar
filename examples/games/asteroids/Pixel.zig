const Color = @import("Color.zig");
const Pixel = @This();

r: u8,
g: u8,
b: u8,
a: u8,
x: i32,
y: i32,

pub fn at(x: i32, y: i32, color: Color) Pixel {
    return Pixel{
        .r = color.r,
        .g = color.g,
        .b = color.b,
        .a = color.a,
        .x = x,
        .y = y,
    };
}
