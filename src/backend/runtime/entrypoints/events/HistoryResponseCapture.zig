const Capture = @This();
const source_namespace = @import("history_response.zig");
const history = @import("../../../history/root.zig");
const FakeSession = @import("FakeSession.zig");
const std = @import("std");
steps: [7]source_namespace.Step = undefined,
len: usize = 0,
expected_client: history.model.ClientKey = .{ .id = 7, .generation = 11 },
resolve_client: bool = true,
rearm_failure: bool = false,
query_queue_accepts: bool = true,
failure_queue_accepts: bool = true,
session: FakeSession = .{},
enqueued_query: ?*history.model.QueryResult = null,
disposed_query: ?*history.model.QueryResult = null,
enqueued_failure: ?history.model.Failure = null,
enqueued_pruned: ?history.model.Pruned = null,

fn record(capture: *Capture, step: source_namespace.Step) void {
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

pub fn resolve(capture: *Capture, client: history.model.ClientKey) ?*FakeSession {
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

pub fn enqueueQueryResult(capture: *Capture, _: *FakeSession, result: *history.model.QueryResult) bool {
    capture.record(.enqueue_query_result);
    capture.enqueued_query = result;
    return capture.query_queue_accepts;
}

pub fn enqueueFailure(capture: *Capture, _: *FakeSession, failure: history.model.Failure) bool {
    capture.record(.enqueue_failure);
    capture.enqueued_failure = failure;
    return capture.failure_queue_accepts;
}

pub fn enqueueStatsResult(capture: *Capture, session: *FakeSession, result: *history.model.StatsResult) bool {
    _ = session;
    _ = result;
    capture.record(.enqueue_stats_result);
    return true;
}

pub fn enqueueOutputResult(capture: *Capture, session: *FakeSession, result: *history.model.OutputResult) bool {
    _ = session;
    _ = result;
    capture.record(.enqueue_output_result);
    return true;
}

pub fn enqueuePruned(capture: *Capture, session: *FakeSession, pruned: history.model.Pruned) bool {
    _ = session;
    capture.record(.enqueue_pruned);
    capture.enqueued_pruned = pruned;
    return true;
}

pub fn disposeQueryResult(capture: *Capture, result: *history.model.QueryResult) void {
    capture.record(.dispose_query_result);
    capture.disposed_query = result;
}

pub fn pumpClients(capture: *Capture) void {
    capture.record(.pump_clients);
}
