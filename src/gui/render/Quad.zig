//! The only primitive the native backend draws: one textured rectangle in
//! device pixels, optionally rounded and outlined. Its layout is the wire
//! format of a frame, so it mirrors `telar_gui_quad` in `native/telar_gui.h`
//! field for field and the `Quad` struct of both shaders.

/// Texture coordinates of the opaque white texel every atlas reserves, so a
/// solid rectangle is a quad like any other.
pub const solid_uv: [4]f32 = .{ 0.5 / 1024.0, 0.5 / 1024.0, 0.5 / 1024.0, 0.5 / 1024.0 };

/// The fragment shader resolves `radius` and `border` by signed distance in
/// device pixels. Both zero keeps the plain textured path bit for bit, so a
/// glyph or a flat fill costs nothing more than before. The band `border`
/// pixels wide inside the outline takes the border color; the rest of the
/// shape takes the fill color. `texture` selects the sampled page: zero is
/// the alpha glyph atlas read as coverage, one the premultiplied RGBA sprite
/// page whose texel is the color. Values 2 through 9 select diagram slots. One reserved float keeps the std430 stride
/// of five `vec4`s; it is always zero.
pub const Quad = extern struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
    radius: f32 = 0,
    border: f32 = 0,
    texture: f32 = 0,
    reserved: f32 = 0,
    border_r: f32 = 0,
    border_g: f32 = 0,
    border_b: f32 = 0,
    border_a: f32 = 0,
};

/// The std430 stride both shaders index the quad buffer with.
pub const stride: usize = 80;

/// `texture` values both shaders branch on.
pub const atlas_texture: f32 = 0;
pub const sprite_texture: f32 = 1;
pub const diagram_texture: f32 = 2;

comptime {
    const std = @import("std");
    std.debug.assert(@sizeOf(Quad) == stride);
    std.debug.assert(@offsetOf(Quad, "u0") == 16);
    std.debug.assert(@offsetOf(Quad, "r") == 32);
    std.debug.assert(@offsetOf(Quad, "radius") == 48);
    std.debug.assert(@offsetOf(Quad, "texture") == 56);
    std.debug.assert(@offsetOf(Quad, "border_r") == 64);
}
