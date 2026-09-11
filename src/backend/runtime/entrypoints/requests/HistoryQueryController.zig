const ResponseQueueType = @import("../../delivery/ResponseQueue.zig");
const RuntimeMetricsType = @import("../../observability/RuntimeMetrics.zig");
const HistoryExecutor = @import("../../application/queries/HistoryExecutor.zig");
const QueryOriginType = @import("../../../history/QueryOrigin.zig");
const QueryHistoryType = @import("telar-core").QueryHistory;
const enabled_module = @import("telar-core").enabled;
const HistoryQueryFailure = @import("HistoryQueryFailure.zig");
const Controller = @This();

responses: *ResponseQueueType,
metrics: *RuntimeMetricsType,
query: HistoryExecutor,

/// Creates a controller scoped to one history-query request.
///
/// ```zig
/// var controller = Controller.init(&responses, &metrics, handler.executor());
/// ```
pub fn init(responses: *ResponseQueueType, metrics: *RuntimeMetricsType, query: HistoryExecutor) Controller {
    return .{ .responses = responses, .metrics = metrics, .query = query };
}

/// Maps borrowed wire fields and reply ownership to the application query.
/// Successful submission has no immediate response because the history
/// worker later answers the client identified by `origin`.
///
/// ```zig
/// try controller.queryHistory(origin, request);
/// ```
pub fn queryHistory(controller: *Controller, origin: QueryOriginType, request: QueryHistoryType) !void {
    controller.query.execute(.{
        .request_id = request.request_id,
        .origin = origin,
        .text = request.query,
        .scope = request.scope,
        .scope_value = request.scope_value,
        .pane_id = request.pane_id,
        .failed_only = request.failed_only,
        .author = request.author,
        .match = request.match,
        .distinct = request.distinct,
        .limit = request.limit,
        .offset = request.offset,
        .snapshot_id = request.snapshot_id,
        .entry_id = request.entry_id,
    }) catch |err| switch (err) {
        error.InvalidHistoryQuery => {
            try controller.queueFailure(.{
                .request_id = request.request_id,
                .code = .invalid_request,
                .message = "invalid history query",
            });
            return;
        },
        error.HistoryQueueFull => {
            if (comptime enabled_module) {
                controller.metrics.history_query_failures += 1;
            }

            try controller.queueFailure(.{
                .request_id = request.request_id,
                .code = .resource_limit,
                .message = "history queue is full",
            });
            return;
        },
        else => return err,
    };

    if (comptime enabled_module) {
        controller.metrics.history_queries += 1;
    }
}

fn queueFailure(controller: *Controller, failure: HistoryQueryFailure) !void {
    try controller.responses.push(.{ .request_failed = .{
        .request_id = failure.request_id,
        .code = failure.code,
        .message = failure.message,
    } });
}
