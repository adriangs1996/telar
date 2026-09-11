//! Vertical contract tests for history-query submission.

const Submission = @import("Submission.zig");
const HistoryHandler = @import("../application/queries/HistoryHandler.zig");
const ResponseQueueType = @import("../delivery/ResponseQueue.zig");
const RuntimeMetricsType = @import("../observability/RuntimeMetrics.zig");
const HistoryQueryController = @import("../entrypoints/requests/HistoryQueryController.zig");
const RequestIdType = @import("telar-core").RequestId;
const QueryOriginType = @import("../../history/QueryOrigin.zig");
const std = @import("std");
const HistoryScope = @import("telar-core").HistoryScope;
const enabled_module = @import("telar-core").enabled;

test "borrowed protocol bytes become one owned asynchronous history query" {
    var submission: Submission = .{};
    var handler: HistoryHandler = .{ .service = submission.port() };
    var responses: ResponseQueueType = .{};
    var metrics: RuntimeMetricsType = .{ .started_ns = 0 };
    var controller = HistoryQueryController.init(
        &responses,
        &metrics,
        handler.executor(),
    );
    var text = [_]u8{ 'c', 'o', 'm', 'm', 'i', 't' };
    var workspace = [_]u8{ '/', 'w', 'o', 'r', 'k' };
    const request_id: RequestIdType = @enumFromInt(31);
    const origin: QueryOriginType = .{
        .client = .{ .id = 13, .generation = 21 },
        .close_after_reply = true,
    };

    try controller.queryHistory(origin, .{
        .request_id = request_id,
        .query = &text,
        .scope = .workspace,
        .scope_value = &workspace,
        .failed_only = true,
        .limit = 5,
    });
    @memset(&text, 'x');
    @memset(&workspace, 'y');

    const query = &submission.query.?;
    try std.testing.expectEqual(request_id, query.request_id);
    try std.testing.expectEqualDeep(origin, query.origin);
    try std.testing.expectEqualStrings("commit", query.textSlice());
    try std.testing.expectEqual(HistoryScope.workspace, query.scope);
    try std.testing.expectEqualStrings("/work", query.scopeSlice());
    try std.testing.expect(query.failed_only);
    try std.testing.expectEqual(@as(u16, 5), query.limit);
    try std.testing.expect(responses.peek() == null);
    try std.testing.expectEqual(@as(u64, if (enabled_module) 1 else 0), metrics.history_queries);
}
