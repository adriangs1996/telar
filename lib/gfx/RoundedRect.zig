//! A solid surface resolved by the fragment shader: a rounded rectangle with
//! an optional band of `border` pixels inside its outline. Zero radius and
//! zero border is the plain rectangle `QuadList.pushRect` draws.
const Color = @import("Color.zig");

fill: Color,
radius: f32 = 0,
border: f32 = 0,
border_color: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
