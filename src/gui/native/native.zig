//! The C contract with the native backends, `macos/window.m` and
//! `linux/window.c`. Every layout here mirrors a struct in `telar_gui.h`.
pub const Frame = @import("Frame.zig").Frame;
pub const Viewport = @import("Viewport.zig").Viewport;

pub const RenderFn = *const fn (?*anyopaque, Viewport, *Frame) callconv(.c) void;

/// Opens the window, drives the AppKit run loop on the calling thread and
/// returns when the window closes. `render` runs on that same thread.
pub extern fn telar_gui_run(title: [*:0]const u8, context: ?*anyopaque, render: RenderFn) c_int;
