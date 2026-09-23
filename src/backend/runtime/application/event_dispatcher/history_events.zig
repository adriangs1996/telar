const model_module = @import("../../../history/model.zig");
const Session = @import("../../client/Session.zig");
const SourcesType = @import("../../Sources.zig");
const QueryResultType = @import("../../../history/QueryResult.zig");
const FailureType = @import("../../../history/Failure.zig");
const StatsResultType = @import("../../../history/StatsResult.zig");
const OutputResultType = @import("../../../history/OutputResult.zig");
const PrunedType = @import("../../../history/Pruned.zig");
const ResponseQueueType = @import("../../delivery/ResponseQueue.zig");
const PendingFailureType = @import("../../delivery/PendingFailure.zig");

const RuntimeModel = @import("../../RuntimeModel.zig");

/// Rearms the history response source, resolves its client and transfers
/// the result into that client's bounded delivery queue.
///
/// ```zig
/// try HistoryEvents.handle(&model, result);
/// ```
pub fn handle(model: *RuntimeModel, response_result: anyerror!model_module.Response) !void {
    const response = response_result catch return;
    var owned_query: ?*QueryResultType = switch (response) {
        .query_result => |result| result,
        .failed, .pruned, .output_result, .stats_result => null,
    };
    defer if (owned_query) |result| {
        result.deinit();
    };
    var owned_output: ?*OutputResultType = switch (response) {
        .output_result => |result| result,
        else => null,
    };
    defer if (owned_output) |result| {
        result.deinit();
    };
    var owned_stats: ?*StatsResultType = switch (response) {
        .stats_result => |result| result,
        else => null,
    };
    defer if (owned_stats) |result| {
        result.deinit();
    };

    try rearmHistoryResponse(model);

    switch (response) {
        .query_result => |result| {
            const session = (model.clients.resolve(result.origin.client)) orelse return;
            session.delivery.setCloseAfterReply(result.origin.close_after_reply);

            if (enqueueHistoryQueryResult(model, session, result)) {
                owned_query = null;
            } else {
                result.deinit();
                owned_query = null;
            }
        },
        .failed => |failure| {
            const session = (model.clients.resolve(failure.origin.client)) orelse return;
            session.delivery.setCloseAfterReply(failure.origin.close_after_reply);
            _ = enqueueHistoryFailure(model, session, failure);
        },
        .pruned => |pruned| {
            const session = (model.clients.resolve(pruned.origin.client)) orelse return;
            session.delivery.setCloseAfterReply(pruned.origin.close_after_reply);
            _ = enqueueHistoryPruned(model, session, pruned);
        },
        .output_result => |result| {
            const session = (model.clients.resolve(result.origin.client)) orelse return;
            session.delivery.setCloseAfterReply(result.origin.close_after_reply);
            if (enqueueHistoryOutputResult(model, session, result)) {
                owned_output = null;
            }
        },
        .stats_result => |result| {
            const session = (model.clients.resolve(result.origin.client)) orelse return;
            session.delivery.setCloseAfterReply(result.origin.close_after_reply);
            if (enqueueHistoryStatsResult(model, session, result)) {
                owned_stats = null;
            }
        },
    }
}

fn rearmHistoryResponse(model: *RuntimeModel) !void {
    var sources = SourcesType.init(model.io, model.select);
    try sources.receiveHistory(model.resources.history.service());
}

fn enqueueHistoryQueryResult(_: *RuntimeModel, session: *Session, result: *QueryResultType) bool {
    session.delivery.responses.push(.{ .history_result = result }) catch return false;
    return true;
}

fn enqueueHistoryFailure(_: *RuntimeModel, session: *Session, failure: FailureType) bool {
    queueFailure(&session.delivery.responses, .{
        .request_id = failure.request_id,
        .code = .internal,
        .message = failure.message,
    }) catch return false;
    return true;
}

fn enqueueHistoryStatsResult(_: *RuntimeModel, session: *Session, result: *StatsResultType) bool {
    session.delivery.responses.push(.{ .history_stats = result }) catch return false;
    return true;
}

fn enqueueHistoryOutputResult(_: *RuntimeModel, session: *Session, result: *OutputResultType) bool {
    session.delivery.responses.push(.{ .history_output = result }) catch return false;
    return true;
}

fn enqueueHistoryPruned(_: *RuntimeModel, session: *Session, pruned: PrunedType) bool {
    session.delivery.responses.push(.{ .history_pruned = .{
        .request_id = pruned.request_id,
        .removed = pruned.removed,
    } }) catch return false;
    return true;
}

fn queueFailure(responses: *ResponseQueueType, failure: PendingFailureType) !void {
    try responses.push(.{ .request_failed = .{
        .request_id = failure.request_id,
        .code = failure.code,
        .message = failure.message,
    } });
}
