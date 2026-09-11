/// Defines client lookup, delivery mutation, lifecycle effects, and shutdown
/// queries bound by the runtime instance. `Types` declares
/// `Client`, `Session`, `Completion`, and `Detach`; a completion exposes
/// `close_client` and `detach_pane` fields.
///
/// ```zig
/// const port: RuntimePort(Context, Types) = .{ ... };
/// ```
pub fn Type(comptime Context: type, comptime Types: type) type {
    return struct {
        resolve: *const fn (*Context, Types.Client) ?Types.Session,
        record_stale: *const fn (*Context) void,
        release_send: *const fn (*Context, Types.Session) void,
        is_closing: *const fn (*Context, Types.Session) bool,
        finalize: *const fn (*Context, Types.Client) void,
        complete_delivery: *const fn (*Context, Types.Session, anyerror!void) Types.Completion,
        drop_client: *const fn (*Context, Types.Client) void,
        detach_after_send: *const fn (*Context, Types.Session, Types.Detach) void,
        should_close_after_reply: *const fn (*Context, Types.Session) bool,
        stopping: *const fn (*Context) bool,
        pump_client: *const fn (*Context, Types.Session) anyerror!void,
        pump_all: *const fn (*Context) void,
        shutdown_delivered: *const fn (*Context) bool,
    };
}
