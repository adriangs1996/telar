//! The texture coordinates and tint of one sprite-page quad.
const Color = @import("Color.zig");

/// u0, v0, u1, v1 inside the sprite page.
uv: [4]f32,
/// Straight RGBA multiplied into the premultiplied texel; alpha fades it.
tint: Color = Color.white,
