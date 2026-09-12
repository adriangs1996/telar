//! The only primitive the native backend draws: one textured rectangle in
//! device pixels. Its layout is the wire format of a frame, so it mirrors
//! `telar_gui_quad` in `macos/window.m` field for field.

/// Texture coordinates of the opaque white texel every atlas reserves, so a
/// solid rectangle is a quad like any other.
pub const solid_uv: [4]f32 = .{ 0.5 / 1024.0, 0.5 / 1024.0, 0.5 / 1024.0, 0.5 / 1024.0 };

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
};
