//! Routing and ownership policy for asynchronous history responses.

const GenericHistoryResponseRuntimePort = @import("GenericHistoryResponseRuntimePort.zig").Type;
const HistoryResponseCapture = @import("HistoryResponseCapture.zig");
const FakeSession = @import("FakeSession.zig");
const GenericController = @import("GenericController.zig").Type;
const QueryOriginType = @import("../../../history/QueryOrigin.zig");
const EntryType = @import("../../../history/Entry.zig");
const QueryResultType = @import("../../../history/QueryResult.zig");
const std = @import("std");
const FailureType = @import("../../../history/Failure.zig");

pub const Step = enum {
    enqueue_pruned,
    enqueue_output_result,
    enqueue_stats_result,
    rearm_receive,
    resolve,
    set_close_after_reply,
    enqueue_query_result,
    enqueue_failure,
    dispose_query_result,
    pump_clients,
};

const test_port: GenericHistoryResponseRuntimePort(HistoryResponseCapture, *FakeSession) = .{
    .rearm_receive = HistoryResponseCapture.rearmReceive,
    .resolve = HistoryResponseCapture.resolve,
    .set_close_after_reply = HistoryResponseCapture.setCloseAfterReply,
    .enqueue_query_result = HistoryResponseCapture.enqueueQueryResult,
    .enqueue_failure = HistoryResponseCapture.enqueueFailure,
    .enqueue_pruned = HistoryResponseCapture.enqueuePruned,
    .enqueue_output_result = HistoryResponseCapture.enqueueOutputResult,
    .enqueue_stats_result = HistoryResponseCapture.enqueueStatsResult,
    .dispose_query_result = HistoryResponseCapture.disposeQueryResult,
    .pump_clients = HistoryResponseCapture.pumpClients,
};

const TestController = GenericController(HistoryResponseCapture, *FakeSession, test_port);

fn testQueryResult(origin: QueryOriginType, entries: []EntryType) QueryResultType {
    return .{
        .request_id = @enumFromInt(13),
        .origin = origin,
        .entries = entries,
        .gpa = std.testing.allocator,
    };
}

fn testFailure(origin: QueryOriginType) FailureType {
    return .{
        .request_id = @enumFromInt(17),
        .origin = origin,
        .message = "history unavailable",
    };
}

fn testOrigin(close_after_reply: bool) QueryOriginType {
    return .{
        .client = .{ .id = 7, .generation = 11 },
        .close_after_reply = close_after_reply,
    };
}

fn expectSteps(capture: *const HistoryResponseCapture, expected: []const Step) !void {
    try std.testing.expectEqualSlices(Step, expected, capture.steps[0..capture.len]);
}

test "a failed worker receive ends without rearming or routing" {
    var capture: HistoryResponseCapture = .{};
    var controller = TestController.init(&capture);

    try controller.handle(error.ResponseQueueClosed);

    try expectSteps(&capture, &.{});
}

test "rearm failure disposes an owned query result before propagating" {
    var entries: [0]EntryType = .{};
    var result = testQueryResult(testOrigin(false), &entries);
    var capture: HistoryResponseCapture = .{ .rearm_failure = true };
    var controller = TestController.init(&capture);

    try std.testing.expectError(error.SchedulerUnavailable, controller.handle(.{ .query_result = &result }));

    try expectSteps(&capture, &.{ .rearm_receive, .dispose_query_result });
    try std.testing.expect(capture.disposed_query == &result);
}

test "a stale query result is disposed without pumping clients" {
    var entries: [0]EntryType = .{};
    var result = testQueryResult(testOrigin(false), &entries);
    var capture: HistoryResponseCapture = .{ .resolve_client = false };
    var controller = TestController.init(&capture);

    try controller.handle(.{ .query_result = &result });

    try expectSteps(&capture, &.{ .rearm_receive, .resolve, .dispose_query_result });
    try std.testing.expect(capture.disposed_query == &result);
}

test "an accepted query result transfers ownership before pumping" {
    var entries: [0]EntryType = .{};
    var result = testQueryResult(testOrigin(true), &entries);
    var capture: HistoryResponseCapture = .{};
    var controller = TestController.init(&capture);

    try controller.handle(.{ .query_result = &result });

    try expectSteps(&capture, &.{
        .rearm_receive,
        .resolve,
        .set_close_after_reply,
        .enqueue_query_result,
        .pump_clients,
    });
    try std.testing.expect(capture.session.close_after_reply);
    try std.testing.expect(capture.enqueued_query == &result);
    try std.testing.expect(capture.disposed_query == null);
}

test "query response backpressure disposes before pumping" {
    var entries: [0]EntryType = .{};
    var result = testQueryResult(testOrigin(false), &entries);
    var capture: HistoryResponseCapture = .{ .query_queue_accepts = false };
    var controller = TestController.init(&capture);

    try controller.handle(.{ .query_result = &result });

    try expectSteps(&capture, &.{
        .rearm_receive,
        .resolve,
        .set_close_after_reply,
        .enqueue_query_result,
        .dispose_query_result,
        .pump_clients,
    });
    try std.testing.expect(capture.disposed_query == &result);
}

test "a stale failure response has no owned value or delivery effects" {
    var capture: HistoryResponseCapture = .{ .resolve_client = false };
    var controller = TestController.init(&capture);

    try controller.handle(.{ .failed = testFailure(testOrigin(true)) });

    try expectSteps(&capture, &.{ .rearm_receive, .resolve });
    try std.testing.expect(capture.disposed_query == null);
}

test "failure response backpressure still leaves a delivery opportunity" {
    var capture: HistoryResponseCapture = .{ .failure_queue_accepts = false };
    var controller = TestController.init(&capture);

    try controller.handle(.{ .failed = testFailure(testOrigin(true)) });

    try expectSteps(&capture, &.{
        .rearm_receive,
        .resolve,
        .set_close_after_reply,
        .enqueue_failure,
        .pump_clients,
    });
    try std.testing.expect(capture.session.close_after_reply);
    try std.testing.expectEqualStrings("history unavailable", capture.enqueued_failure.?.message);
}
