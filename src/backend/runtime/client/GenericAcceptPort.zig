/// Defines shutdown policy and socket effects bound by the runtime instance.
///
/// ```zig
/// const port: AcceptPort(Context, Connection) = .{ ... };
/// ```
pub fn Type(comptime Context: type, comptime Connection: type) type {
    return struct {
        stopping: *const fn (*Context) bool,
        rearm_accept: *const fn (*Context) anyerror!void,
        has_capacity: *const fn (*Context) bool,
        shutdown_connection: *const fn (*Context, *Connection) void,
        deinit_connection: *const fn (*Context, *Connection) void,
        start_handshake: *const fn (*Context, *Connection) anyerror!void,
    };
}
