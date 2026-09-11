/// Defines negotiated-connection admission and first-read effects bound by the
/// runtime instance. `Types` declares `Connection` and `Session`.
/// `admit` takes connection ownership only when it returns successfully.
///
/// ```zig
/// const port: HandshakePort(Context, Types) = .{ ... };
/// ```
pub fn Type(comptime Context: type, comptime Types: type) type {
    return struct {
        stopping: *const fn (*Context) bool,
        deinit_connection: *const fn (*Context, *Types.Connection) void,
        admit: *const fn (*Context, Types.Connection) anyerror!Types.Session,
        start_receive: *const fn (*Context, Types.Session) anyerror!void,
        drop_session: *const fn (*Context, Types.Session) void,
    };
}
