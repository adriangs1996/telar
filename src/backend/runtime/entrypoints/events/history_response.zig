//! Routing and ownership policy for asynchronous history responses.

const std = @import("std");
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
pub fn RuntimePort(comptime Context: type, comptime Session: type) type {
    return struct {
        rearm_receive: *const fn (*Context) anyerror!void,
        resolve: *const fn (*Context, history.model.ClientKey) ?Session,
        set_close_after_reply: *const fn (*Context, Session, bool) void,
        enqueue_query_result: *const fn (*Context, Session, *history.model.QueryResult) bool,
        enqueue_failure: *const fn (*Context, Session, history.model.Failure) bool,
        enqueue_pruned: *const fn (*Context, Session, history.model.Pruned) bool,
        dispose_query_result: *const fn (*Context, *history.model.QueryResult) void,
        pump_clients: *const fn (*Context) void,
    };
}

/// Creates a statically dispatched history-response controller.
///
/// ```zig
/// const HistoryResponseController = Controller(Context, Session, port);
/// ```
pub fn Controller(comptime Context: type, comptime Session: type, comptime port: RuntimePort(Context, Session)) type {
    return struct {
        const Self = @This();

        context: *Context,

        /// Binds history response ownership and delivery to one runtime.
        ///
        /// ```zig
        /// var controller = HistoryResponseController.init(&context);
        /// ```
        pub fn init(context: *Context) Self {
            return .{ .context = context };
        }

        /// Rearms the worker response receive before routing the current value.
        /// Query results remain owned by this call until a client queue accepts
        /// them; stale routing, backpressure, and rearm failure dispose them.
        /// Worker receive failure ends the response stream without new effects.
        ///
        /// ```zig
        /// try controller.handle(response_result);
        /// ```
        pub fn handle(controller: *Self, response_result: anyerror!history.Response) !void {
            const response = response_result catch return;
            var owned_query: ?*history.model.QueryResult = switch (response) {
                .query_result => |result| result,
                .failed, .pruned => null,
            };
            defer if (owned_query) |result| {
                port.dispose_query_result(controller.context, result);
            };

            try port.rearm_receive(controller.context);

            switch (response) {
                .query_result => |result| {
                    const session = port.resolve(controller.context, result.origin.client) orelse return;
                    port.set_close_after_reply(controller.context, session, result.origin.close_after_reply);

                    if (port.enqueue_query_result(controller.context, session, result)) {
                        owned_query = null;
                    } else {
                        port.dispose_query_result(controller.context, result);
                        owned_query = null;
                    }
                },
                .failed => |failure| {
                    const session = port.resolve(controller.context, failure.origin.client) orelse return;
                    port.set_close_after_reply(controller.context, session, failure.origin.close_after_reply);
                    _ = port.enqueue_failure(controller.context, session, failure);
                },
                .pruned => |pruned| {
                    const session = port.resolve(controller.context, pruned.origin.client) orelse return;
                    port.set_close_after_reply(controller.context, session, pruned.origin.close_after_reply);
                    _ = port.enqueue_pruned(controller.context, session, pruned);
                },
            }

            port.pump_clients(controller.context);
        }
    };
}

const FakeSession = struct {
    close_after_reply: bool = false,
};

const Step = enum {
    enqueue_pruned,
    rearm_receive,
    resolve,
    set_close_after_reply,
    enqueue_query_result,
    enqueue_failure,
    dispose_query_result,
    pump_clients,
};

const Capture = struct {
    steps: [7]Step = undefined,
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

    fn record(capture: *Capture, step: Step) void {
        std.debug.assert(capture.len < capture.steps.len);
        capture.steps[capture.len] = step;
        capture.len += 1;
    }

    fn rearmReceive(capture: *Capture) !void {
        capture.record(.rearm_receive);

        if (capture.rearm_failure) {
            return error.SchedulerUnavailable;
        }
    }

    fn resolve(capture: *Capture, client: history.model.ClientKey) ?*FakeSession {
        capture.record(.resolve);

        if (!capture.resolve_client or !std.meta.eql(client, capture.expected_client)) {
            return null;
        }

        return &capture.session;
    }

    fn setCloseAfterReply(capture: *Capture, session: *FakeSession, enabled: bool) void {
        capture.record(.set_close_after_reply);
        session.close_after_reply = enabled;
    }

    fn enqueueQueryResult(capture: *Capture, _: *FakeSession, result: *history.model.QueryResult) bool {
        capture.record(.enqueue_query_result);
        capture.enqueued_query = result;
        return capture.query_queue_accepts;
    }

    fn enqueueFailure(capture: *Capture, _: *FakeSession, failure: history.model.Failure) bool {
        capture.record(.enqueue_failure);
        capture.enqueued_failure = failure;
        return capture.failure_queue_accepts;
    }

    fn enqueuePruned(capture: *Capture, session: *FakeSession, pruned: history.model.Pruned) bool {
        _ = session;
        capture.record(.enqueue_pruned);
        capture.enqueued_pruned = pruned;
        return true;
    }

    fn disposeQueryResult(capture: *Capture, result: *history.model.QueryResult) void {
        capture.record(.dispose_query_result);
        capture.disposed_query = result;
    }

    fn pumpClients(capture: *Capture) void {
        capture.record(.pump_clients);
    }
};

const test_port: RuntimePort(Capture, *FakeSession) = .{
    .rearm_receive = Capture.rearmReceive,
    .resolve = Capture.resolve,
    .set_close_after_reply = Capture.setCloseAfterReply,
    .enqueue_query_result = Capture.enqueueQueryResult,
    .enqueue_failure = Capture.enqueueFailure,
    .enqueue_pruned = Capture.enqueuePruned,
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
