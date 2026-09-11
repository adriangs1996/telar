//! Request-scoped controller for history-query protocol messages.

const QueryOrigin = @import("../../../history/QueryOrigin.zig");
const QueryHistoryType = @import("telar-core").QueryHistory;
const ResponseQueue = @import("../../delivery/ResponseQueue.zig");
const RuntimeMetrics = @import("../../observability/RuntimeMetrics.zig");
const HistoryQueryStubQuery = @import("HistoryQueryStubQuery.zig");
const HistoryQueryController = @import("HistoryQueryController.zig");
const std = @import("std");
const enabled_module = @import("telar-core").enabled;
const FailureCodeType = @import("telar-core").FailureCode;

fn testingOrigin() QueryOrigin {
    return .{
        .client = .{ .id = 4, .generation = 9 },
        .close_after_reply = true,
    };
}

fn testingRequest() QueryHistoryType {
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
    var stub: HistoryQueryStubQuery = .{};
    var controller = HistoryQueryController.init(&responses, &metrics, stub.executor());
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
    try std.testing.expectEqual(@as(u64, if (enabled_module) 1 else 0), metrics.history_queries);
    try std.testing.expectEqual(@as(u64, 0), metrics.history_query_failures);
}

test "Controller maps an invalid query without recording service failure" {
    var responses: ResponseQueue = .{};
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var stub: HistoryQueryStubQuery = .{ .failure = error.InvalidHistoryQuery };
    var controller = HistoryQueryController.init(&responses, &metrics, stub.executor());
    const request = testingRequest();

    try controller.queryHistory(testingOrigin(), request);

    const failure = responses.peek().?.request_failed;
    try std.testing.expectEqual(request.request_id, failure.request_id);
    try std.testing.expectEqual(FailureCodeType.invalid_request, failure.code);
    try std.testing.expectEqualStrings("invalid history query", failure.message);
    try std.testing.expectEqual(@as(u64, 0), metrics.history_queries);
    try std.testing.expectEqual(@as(u64, 0), metrics.history_query_failures);
}

test "Controller maps service backpressure and records it before replying" {
    var responses: ResponseQueue = .{};
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var stub: HistoryQueryStubQuery = .{ .failure = error.HistoryQueueFull };
    var controller = HistoryQueryController.init(&responses, &metrics, stub.executor());
    const request = testingRequest();

    try controller.queryHistory(testingOrigin(), request);

    const failure = responses.peek().?.request_failed;
    try std.testing.expectEqual(request.request_id, failure.request_id);
    try std.testing.expectEqual(FailureCodeType.resource_limit, failure.code);
    try std.testing.expectEqualStrings("history queue is full", failure.message);
    try std.testing.expectEqual(@as(u64, 0), metrics.history_queries);
    try std.testing.expectEqual(@as(u64, if (enabled_module) 1 else 0), metrics.history_query_failures);
}

test "Controller propagates unexpected query failures without side effects" {
    var responses: ResponseQueue = .{};
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var stub: HistoryQueryStubQuery = .{ .failure = error.HistoryUnavailable };
    var controller = HistoryQueryController.init(&responses, &metrics, stub.executor());

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
    var stub: HistoryQueryStubQuery = .{ .failure = error.HistoryQueueFull };
    var controller = HistoryQueryController.init(&responses, &metrics, stub.executor());

    try std.testing.expectError(error.ResponseQueueFull, controller.queryHistory(
        testingOrigin(),
        testingRequest(),
    ));

    try std.testing.expectEqual(@as(u8, responses.items.len), responses.len);
    try std.testing.expectEqual(@as(u64, if (enabled_module) 1 else 0), metrics.history_query_failures);
}
