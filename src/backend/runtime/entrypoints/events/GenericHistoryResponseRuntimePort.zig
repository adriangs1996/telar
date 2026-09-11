const ClientKeyType = @import("../../../history/ClientKey.zig");
const QueryResultType = @import("../../../history/QueryResult.zig");
const FailureType = @import("../../../history/Failure.zig");
const PrunedType = @import("../../../history/Pruned.zig");
const OutputResultType = @import("../../../history/OutputResult.zig");
const StatsResultType = @import("../../../history/StatsResult.zig");

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
        resolve: *const fn (*Context, ClientKeyType) ?Session,
        set_close_after_reply: *const fn (*Context, Session, bool) void,
        enqueue_query_result: *const fn (*Context, Session, *QueryResultType) bool,
        enqueue_failure: *const fn (*Context, Session, FailureType) bool,
        enqueue_pruned: *const fn (*Context, Session, PrunedType) bool,
        enqueue_output_result: *const fn (*Context, Session, *OutputResultType) bool,
        enqueue_stats_result: *const fn (*Context, Session, *StatsResultType) bool,
        dispose_query_result: *const fn (*Context, *QueryResultType) void,
        pump_clients: *const fn (*Context) void,
    };
}
