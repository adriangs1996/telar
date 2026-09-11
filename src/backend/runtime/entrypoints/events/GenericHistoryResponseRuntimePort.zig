const history = @import("../../../history/root.zig");
/// Defines history receiving, client lookup, response queuing, and delivery
/// bound by the runtime instance.
///
/// `enqueue_query_result` takes ownership only when it returns true. Failure
/// responses contain no owned allocation and may be dropped on backpressure.
///
/// ```zig
/// const port: RuntimePort(Context, Session) = .{ ... };
/// ```
pub fn Type(comptime Context: type, comptime Session: type) type {
    return struct {
        rearm_receive: *const fn (*Context) anyerror!void,
        resolve: *const fn (*Context, history.model.ClientKey) ?Session,
        set_close_after_reply: *const fn (*Context, Session, bool) void,
        enqueue_query_result: *const fn (*Context, Session, *history.model.QueryResult) bool,
        enqueue_failure: *const fn (*Context, Session, history.model.Failure) bool,
        enqueue_pruned: *const fn (*Context, Session, history.model.Pruned) bool,
        enqueue_output_result: *const fn (*Context, Session, *history.model.OutputResult) bool,
        enqueue_stats_result: *const fn (*Context, Session, *history.model.StatsResult) bool,
        dispose_query_result: *const fn (*Context, *history.model.QueryResult) void,
        pump_clients: *const fn (*Context) void,
    };
}
