//! Native backends borrow frame bytes only through their submission. Completion
//! runs on the window thread after the GPU stops consuming that submission.
pub const Frame = @import("Frame.zig").Frame;
pub const Viewport = @import("Viewport.zig").Viewport;
pub const InputEvent = @import("InputEvent.zig").InputEvent;
pub const Callbacks = @import("Callbacks.zig").Callbacks;

pub extern fn telar_gui_run(title: [*:0]const u8, context: ?*anyopaque, callbacks: *const Callbacks) c_int;
pub extern fn telar_gui_pipe(fds: *[2]c_int) c_int;
pub extern fn telar_gui_wake(fd: c_int) void;
pub extern fn telar_gui_drain(fd: c_int) void;
pub extern fn telar_gui_close_pipe(fds: *[2]c_int) void;
pub extern fn telar_gui_clipboard(bytes: [*]const u8, len: usize) c_int;
pub extern fn telar_gui_local_time(output: *[7]u16) void;
