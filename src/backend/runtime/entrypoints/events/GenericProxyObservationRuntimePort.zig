/// Defines proxy receive scheduling and downstream effects bound by the
/// runtime instance.
///
/// ```zig
/// const port: RuntimePort(Context) = .{ ... };
/// ```
pub fn Type(comptime Context: type) type {
    return struct {
        rearm_receive: *const fn (*Context) anyerror!void,
        schedule_description: *const fn (*Context) void,
        pump_clients: *const fn (*Context) void,
    };
}
