//! The drawable the backend is about to paint, in device pixels. Mirrors
//! `telar_gui_viewport` in `window.m`.

pub const Viewport = extern struct {
    width: u32,
    height: u32,
    scale: f32,
};
