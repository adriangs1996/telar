//! Vertical contract tests for history-query submission.

const std = @import("std");
const core = @import("telar-core");
const history_mod = @import("../../history/root.zig");
const history_query = @import("../application/queries/history.zig");
const history_query_controller = @import("../entrypoints/requests/history_query.zig");
const delivery_mod = @import("../delivery/root.zig");
const telemetry_mod = @import("../observability/root.zig").telemetry;

const diagnostics = core.diagnostics;
const schema = core.schema;

const Submission = struct {
    query: ?history_mod.Query = null,

    fn port(submission: *Submission) history_query.ServicePort {
        return .{ .context = submission, .submit_fn = submit };
    }

    fn submit(context: *anyopaque, query: history_mod.Query) bool {
        const submission: *Submission = @ptrCast(@alignCast(context));
        submission.query = query;
        return true;
    }
};

test "borrowed protocol bytes become one owned asynchronous history query" {
    var submission: Submission = .{};
    var handler: history_query.Handler = .{ .service = submission.port() };
    var responses: delivery_mod.ResponseQueue = .{};
    var metrics: telemetry_mod.RuntimeMetrics = .{ .started_ns = 0 };
    var controller = history_query_controller.Controller.init(
        &responses,
        &metrics,
        handler.executor(),
    );
    var text = [_]u8{ 'c', 'o', 'm', 'm', 'i', 't' };
    var workspace = [_]u8{ '/', 'w', 'o', 'r', 'k' };
    const request_id: schema.RequestId = @enumFromInt(31);
    const origin: history_mod.model.QueryOrigin = .{
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
    try std.testing.expectEqual(history_mod.model.Scope.workspace, query.scope);
    try std.testing.expectEqualStrings("/work", query.scopeSlice());
    try std.testing.expect(query.failed_only);
    try std.testing.expectEqual(@as(u16, 5), query.limit);
    try std.testing.expect(responses.peek() == null);
    try std.testing.expectEqual(@as(u64, if (diagnostics.enabled) 1 else 0), metrics.history_queries);
}
