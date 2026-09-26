//! The drawable the backend is about to paint, in device pixels. Mirrors
//! `telar_gui_viewport` in `native/telar_gui.h`.

pub const Viewport = extern struct {
    width: u32,
    height: u32,
    scale: f32,
    /// Device pixels the window's own controls cover at the left of the top
    /// row: macOS traffic lights over a transparent titlebar, else zero.
    controls: u32 = 0,
};
