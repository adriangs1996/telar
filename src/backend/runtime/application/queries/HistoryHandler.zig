const ServicePort = @import("ServicePort.zig");
const HistoryRequest = @import("HistoryRequest.zig");
const QueryType = @import("../../../history/Query.zig");
const HistoryExecutor = @import("HistoryExecutor.zig");
const Handler = @This();

service: ServicePort,

/// Copies all borrowed request bytes before attempting bounded submission.
/// Invalid values and service backpressure have distinct application
/// errors; the eventual history result is handled asynchronously.
///
/// ```zig
/// try handler.execute(request);
/// ```
pub fn execute(handler: *Handler, request: HistoryRequest) !void {
    const query = QueryType.init(.{
        .request_id = request.request_id,
        .origin = request.origin,
        .text = request.text,
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
    }) catch {
        return error.InvalidHistoryQuery;
    };

    if (!handler.service.submit(query)) {
        return error.HistoryQueueFull;
    }
}

/// Exposes this handler through the query interface used by controllers.
///
/// ```zig
/// const executor = handler.executor();
/// ```
pub fn executor(handler: *Handler) HistoryExecutor {
    return .{ .context = handler, .execute_fn = executeErased };
}

fn executeErased(context: *anyopaque, request: HistoryRequest) !void {
    const handler: *Handler = @ptrCast(@alignCast(context));
    return handler.execute(request);
}
