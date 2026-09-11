//! Routing and ownership policy for asynchronous history responses.

const std = @import("std");
const history = @import("../../../history/root.zig");

pub const RuntimePort = @import("GenericHistoryResponseRuntimePort.zig").Type;

pub const Controller = @import("GenericController.zig").Type;

const FakeSession = @import("FakeSession.zig");

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

const Capture = @import("HistoryResponseCapture.zig");

const test_port: RuntimePort(Capture, *FakeSession) = .{
    .rearm_receive = Capture.rearmReceive,
    .resolve = Capture.resolve,
    .set_close_after_reply = Capture.setCloseAfterReply,
    .enqueue_query_result = Capture.enqueueQueryResult,
    .enqueue_failure = Capture.enqueueFailure,
    .enqueue_pruned = Capture.enqueuePruned,
    .enqueue_output_result = Capture.enqueueOutputResult,
    .enqueue_stats_result = Capture.enqueueStatsResult,
    .dispose_query_result = Capture.disposeQueryResult,
    .pump_clients = Capture.pumpClients,
};

const TestController = Controller(Capture, *FakeSession, test_port);

fn testQueryResult(origin: history.model.QueryOrigin, entries: []history.model.Entry) history.model.QueryResult {
    return .{
        .request_id = @enumFromInt(13),
        .origin = origin,
        .entries = entries,
        .gpa = std.testing.allocator,
    };
}

fn testFailure(origin: history.model.QueryOrigin) history.model.Failure {
    return .{
        .request_id = @enumFromInt(17),
        .origin = origin,
        .message = "history unavailable",
    };
}

fn testOrigin(close_after_reply: bool) history.model.QueryOrigin {
    return .{
        .client = .{ .id = 7, .generation = 11 },
        .close_after_reply = close_after_reply,
    };
}

fn expectSteps(capture: *const Capture, expected: []const Step) !void {
    try std.testing.expectEqualSlices(Step, expected, capture.steps[0..capture.len]);
}

test "a failed worker receive ends without rearming or routing" {
    var capture: Capture = .{};
    var controller = TestController.init(&capture);

    try controller.handle(error.ResponseQueueClosed);

    try expectSteps(&capture, &.{});
}

test "rearm failure disposes an owned query result before propagating" {
    var entries: [0]history.model.Entry = .{};
    var result = testQueryResult(testOrigin(false), &entries);
    var capture: Capture = .{ .rearm_failure = true };
    var controller = TestController.init(&capture);

    try std.testing.expectError(error.SchedulerUnavailable, controller.handle(.{ .query_result = &result }));

    try expectSteps(&capture, &.{ .rearm_receive, .dispose_query_result });
    try std.testing.expect(capture.disposed_query == &result);
}

test "a stale query result is disposed without pumping clients" {
    var entries: [0]history.model.Entry = .{};
    var result = testQueryResult(testOrigin(false), &entries);
    var capture: Capture = .{ .resolve_client = false };
    var controller = TestController.init(&capture);

    try controller.handle(.{ .query_result = &result });

    try expectSteps(&capture, &.{ .rearm_receive, .resolve, .dispose_query_result });
    try std.testing.expect(capture.disposed_query == &result);
}

test "an accepted query result transfers ownership before pumping" {
    var entries: [0]history.model.Entry = .{};
    var result = testQueryResult(testOrigin(true), &entries);
    var capture: Capture = .{};
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
    var entries: [0]history.model.Entry = .{};
    var result = testQueryResult(testOrigin(false), &entries);
    var capture: Capture = .{ .query_queue_accepts = false };
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
    var capture: Capture = .{ .resolve_client = false };
    var controller = TestController.init(&capture);

    try controller.handle(.{ .failed = testFailure(testOrigin(true)) });

    try expectSteps(&capture, &.{ .rearm_receive, .resolve });
    try std.testing.expect(capture.disposed_query == null);
}

test "failure response backpressure still leaves a delivery opportunity" {
    var capture: Capture = .{ .failure_queue_accepts = false };
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
