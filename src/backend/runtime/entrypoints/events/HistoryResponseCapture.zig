const history_response = @import("history_response.zig");
const ClientKeyType = @import("../../../history/ClientKey.zig");
const FakeSession = @import("FakeSession.zig");
const QueryResultType = @import("../../../history/QueryResult.zig");
const FailureType = @import("../../../history/Failure.zig");
const PrunedType = @import("../../../history/Pruned.zig");
const std = @import("std");
const StatsResultType = @import("../../../history/StatsResult.zig");
const OutputResultType = @import("../../../history/OutputResult.zig");
const Capture = @This();

steps: [7]history_response.Step = undefined,
len: usize = 0,
expected_client: ClientKeyType = .{ .id = 7, .generation = 11 },
resolve_client: bool = true,
rearm_failure: bool = false,
query_queue_accepts: bool = true,
failure_queue_accepts: bool = true,
session: FakeSession = .{},
enqueued_query: ?*QueryResultType = null,
disposed_query: ?*QueryResultType = null,
enqueued_failure: ?FailureType = null,
enqueued_pruned: ?PrunedType = null,

fn record(capture: *Capture, step: history_response.Step) void {
    std.debug.assert(capture.len < capture.steps.len);
    capture.steps[capture.len] = step;
    capture.len += 1;
}

pub fn rearmReceive(capture: *Capture) !void {
    capture.record(.rearm_receive);

    if (capture.rearm_failure) {
        return error.SchedulerUnavailable;
    }
}

pub fn resolve(capture: *Capture, client: ClientKeyType) ?*FakeSession {
    capture.record(.resolve);

    if (!capture.resolve_client or !std.meta.eql(client, capture.expected_client)) {
        return null;
    }

    return &capture.session;
}

pub fn setCloseAfterReply(capture: *Capture, session: *FakeSession, enabled: bool) void {
    capture.record(.set_close_after_reply);
    session.close_after_reply = enabled;
}

pub fn enqueueQueryResult(capture: *Capture, _: *FakeSession, result: *QueryResultType) bool {
    capture.record(.enqueue_query_result);
    capture.enqueued_query = result;
    return capture.query_queue_accepts;
}

pub fn enqueueFailure(capture: *Capture, _: *FakeSession, failure: FailureType) bool {
    capture.record(.enqueue_failure);
    capture.enqueued_failure = failure;
    return capture.failure_queue_accepts;
}

pub fn enqueueStatsResult(capture: *Capture, session: *FakeSession, result: *StatsResultType) bool {
    _ = session;
    _ = result;
    capture.record(.enqueue_stats_result);
    return true;
}

pub fn enqueueOutputResult(capture: *Capture, session: *FakeSession, result: *OutputResultType) bool {
    _ = session;
    _ = result;
    capture.record(.enqueue_output_result);
    return true;
}

pub fn enqueuePruned(capture: *Capture, session: *FakeSession, pruned: PrunedType) bool {
    _ = session;
    capture.record(.enqueue_pruned);
    capture.enqueued_pruned = pruned;
    return true;
}

pub fn disposeQueryResult(capture: *Capture, result: *QueryResultType) void {
    capture.record(.dispose_query_result);
    capture.disposed_query = result;
}

pub fn pumpClients(capture: *Capture) void {
    capture.record(.pump_clients);
}
