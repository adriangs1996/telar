/// Defines scheduling and clock operations supplied by runtime composition.
///
/// ```zig
/// const port: RuntimePort(Application) = .{ .rearm_receive = rearm, .now_ms = now };
/// ```
pub fn Type(comptime Context: type) type {
    return struct {
        rearm_receive: *const fn (*Context) anyerror!void,
        now_ms: *const fn (*Context) i64,
    };
}
