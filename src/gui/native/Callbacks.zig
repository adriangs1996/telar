const native = @import("native.zig");
pub const Callbacks = extern struct {
    render: *const fn (?*anyopaque, native.Viewport, *native.Frame) callconv(.c) void,
    pump: *const fn (?*anyopaque) callconv(.c) c_int,
    complete: *const fn (?*anyopaque, u64, c_int) callconv(.c) void,
    input: *const fn (?*anyopaque, native.InputEvent) callconv(.c) c_int,
    wake_fd: c_int,
    wakeup_after: ?*const fn (?*anyopaque) callconv(.c) u32 = null,
    pointer_shape: ?*const fn (?*anyopaque) callconv(.c) u32 = null,
    text_context: ?*const fn (?*anyopaque, *native.TextContext) callconv(.c) c_int = null,
    host_request: ?*const fn (?*anyopaque, *native.HostRequest) callconv(.c) c_int = null,
    accessibility: ?*const fn (?*anyopaque, *native.AccessibilityTree) callconv(.c) c_int = null,
    frame_delay_ns: ?*const fn (?*anyopaque) callconv(.c) u64 = null,
};
