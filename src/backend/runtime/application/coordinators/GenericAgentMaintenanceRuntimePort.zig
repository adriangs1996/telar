/// Defines timer rearming, clock access, and client delivery bound by the
/// runtime instance.
///
/// ```zig
/// const port: RuntimePort(Context) = .{ ... };
/// ```
pub fn Type(comptime Context: type) type {
    return struct {
        rearm_tick: *const fn (*Context) anyerror!void,
        now_ms: *const fn (*Context) i64,
        pump_clients: *const fn (*Context) void,
    };
}
