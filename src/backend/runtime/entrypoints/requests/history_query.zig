//! Request-scoped controller for history-query protocol messages.

const std = @import("std");
const core = @import("telar-core");
const history_mod = @import("../../../history/root.zig");
const history_query = @import("../../application/queries/history.zig");
const delivery_mod = @import("../../delivery/root.zig");
const telemetry_mod = @import("../../observability/root.zig").telemetry;

const diagnostics = core.diagnostics;
const schema = core.schema;
const QueryOrigin = history_mod.model.QueryOrigin;
const ResponseQueue = delivery_mod.ResponseQueue;
const RuntimeMetrics = telemetry_mod.RuntimeMetrics;

const Failure = struct {
    request_id: schema.RequestId,
    code: schema.FailureCode,
    message: []const u8,
};

pub const Controller = struct {
    responses: *ResponseQueue,
    metrics: *RuntimeMetrics,
    query: history_query.Executor,

    /// Creates a controller scoped to one history-query request.
    ///
    /// ```zig
    /// var controller = Controller.init(&responses, &metrics, handler.executor());
    /// ```
    pub fn init(responses: *ResponseQueue, metrics: *RuntimeMetrics, query: history_query.Executor) Controller {
        return .{ .responses = responses, .metrics = metrics, .query = query };
    }

    /// Maps borrowed wire fields and reply ownership to the application query.
    /// Successful submission has no immediate response because the history
    /// worker later answers the client identified by `origin`.
    ///
    /// ```zig
    /// try controller.queryHistory(origin, request);
    /// ```
    pub fn queryHistory(controller: *Controller, origin: QueryOrigin, request: schema.QueryHistory) !void {
        controller.query.execute(.{
            .request_id = request.request_id,
            .origin = origin,
            .text = request.query,
            .scope = request.scope,
            .scope_value = request.scope_value,
            .pane_id = request.pane_id,
            .failed_only = request.failed_only,
            .limit = request.limit,
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
                if (comptime diagnostics.enabled) {
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

        if (comptime diagnostics.enabled) {
            controller.metrics.history_queries += 1;
        }
    }

    fn queueFailure(controller: *Controller, failure: Failure) !void {
        try controller.responses.push(.{ .request_failed = .{
            .request_id = failure.request_id,
            .code = failure.code,
            .message = failure.message,
        } });
    }
};

const StubQuery = struct {
    failure: ?anyerror = null,
    calls: usize = 0,
    request: ?history_query.Request = null,

    fn executor(stub: *StubQuery) history_query.Executor {
        return .{ .context = stub, .execute_fn = execute };
    }

    fn execute(context: *anyopaque, request: history_query.Request) anyerror!void {
        const stub: *StubQuery = @ptrCast(@alignCast(context));
        stub.calls += 1;
        stub.request = request;

        if (stub.failure) |failure| {
            return failure;
        }
    }
};

fn testingOrigin() QueryOrigin {
    return .{
        .client = .{ .id = 4, .generation = 9 },
        .close_after_reply = true,
    };
}

fn testingRequest() schema.QueryHistory {
    return .{
        .request_id = @enumFromInt(17),
        .query = "status",
        .scope = .cwd,
        .scope_value = "/work",
        .failed_only = true,
        .limit = 7,
    };
}

fn fillResponses(responses: *ResponseQueue) !void {
    while (responses.len < responses.items.len) {
        try responses.push(.{ .request_failed = .{
            .request_id = @enumFromInt(responses.len + 1),
            .code = .invalid_request,
            .message = "occupied",
        } });
    }
}

test "Controller submits every wire field with the asynchronous reply origin" {
    var responses: ResponseQueue = .{};
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var stub: StubQuery = .{};
    var controller = Controller.init(&responses, &metrics, stub.executor());
    const origin = testingOrigin();
    const request = testingRequest();

    try controller.queryHistory(origin, request);

    try std.testing.expectEqual(@as(usize, 1), stub.calls);
    try std.testing.expectEqual(request.request_id, stub.request.?.request_id);
    try std.testing.expectEqualDeep(origin, stub.request.?.origin);
    try std.testing.expectEqualStrings(request.query, stub.request.?.text);
    try std.testing.expectEqual(request.scope, stub.request.?.scope);
    try std.testing.expectEqualStrings(request.scope_value, stub.request.?.scope_value);
    try std.testing.expectEqual(request.pane_id, stub.request.?.pane_id);
    try std.testing.expectEqual(request.failed_only, stub.request.?.failed_only);
    try std.testing.expectEqual(request.limit, stub.request.?.limit);
    try std.testing.expect(responses.peek() == null);
    try std.testing.expectEqual(@as(u64, if (diagnostics.enabled) 1 else 0), metrics.history_queries);
    try std.testing.expectEqual(@as(u64, 0), metrics.history_query_failures);
}

test "Controller maps an invalid query without recording service failure" {
    var responses: ResponseQueue = .{};
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var stub: StubQuery = .{ .failure = error.InvalidHistoryQuery };
    var controller = Controller.init(&responses, &metrics, stub.executor());
    const request = testingRequest();

    try controller.queryHistory(testingOrigin(), request);

    const failure = responses.peek().?.request_failed;
    try std.testing.expectEqual(request.request_id, failure.request_id);
    try std.testing.expectEqual(schema.FailureCode.invalid_request, failure.code);
    try std.testing.expectEqualStrings("invalid history query", failure.message);
    try std.testing.expectEqual(@as(u64, 0), metrics.history_queries);
    try std.testing.expectEqual(@as(u64, 0), metrics.history_query_failures);
}

test "Controller maps service backpressure and records it before replying" {
    var responses: ResponseQueue = .{};
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var stub: StubQuery = .{ .failure = error.HistoryQueueFull };
    var controller = Controller.init(&responses, &metrics, stub.executor());
    const request = testingRequest();

    try controller.queryHistory(testingOrigin(), request);

    const failure = responses.peek().?.request_failed;
    try std.testing.expectEqual(request.request_id, failure.request_id);
    try std.testing.expectEqual(schema.FailureCode.resource_limit, failure.code);
    try std.testing.expectEqualStrings("history queue is full", failure.message);
    try std.testing.expectEqual(@as(u64, 0), metrics.history_queries);
    try std.testing.expectEqual(@as(u64, if (diagnostics.enabled) 1 else 0), metrics.history_query_failures);
}

test "Controller propagates unexpected query failures without side effects" {
    var responses: ResponseQueue = .{};
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var stub: StubQuery = .{ .failure = error.HistoryUnavailable };
    var controller = Controller.init(&responses, &metrics, stub.executor());

    try std.testing.expectError(error.HistoryUnavailable, controller.queryHistory(
        testingOrigin(),
        testingRequest(),
    ));

    try std.testing.expect(responses.peek() == null);
    try std.testing.expectEqual(@as(u64, 0), metrics.history_queries);
    try std.testing.expectEqual(@as(u64, 0), metrics.history_query_failures);
}

test "Controller reports response backpressure after recording queue rejection" {
    var responses: ResponseQueue = .{};
    try fillResponses(&responses);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var stub: StubQuery = .{ .failure = error.HistoryQueueFull };
    var controller = Controller.init(&responses, &metrics, stub.executor());

    try std.testing.expectError(error.ResponseQueueFull, controller.queryHistory(
        testingOrigin(),
        testingRequest(),
    ));

    try std.testing.expectEqual(@as(u8, responses.items.len), responses.len);
    try std.testing.expectEqual(@as(u64, if (diagnostics.enabled) 1 else 0), metrics.history_query_failures);
}
