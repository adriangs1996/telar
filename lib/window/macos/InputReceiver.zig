const native = @import("../native.zig");

// Borrowed, synchronous event admission. The native view disconnects it before
// its window-owned queue is freed; payload bytes are valid only during receive.
pub const InputReceiver = extern struct {
    context: *anyopaque,
    receive: *const fn (*anyopaque, native.c.telar_gui_input) callconv(.c) bool,
};
