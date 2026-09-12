const native = @import("native.zig");
pub const Callbacks = extern struct {
    render: *const fn (?*anyopaque, native.Viewport, *native.Frame) callconv(.c) void,
    pump: *const fn (?*anyopaque) callconv(.c) c_int,
    complete: *const fn (?*anyopaque, u64, c_int) callconv(.c) void,
    input: *const fn (?*anyopaque, native.InputEvent) callconv(.c) c_int,
    wake_fd: c_int,
};
