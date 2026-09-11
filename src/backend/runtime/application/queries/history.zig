//! Application boundary for submitting owned history queries.

const HistoryRequest = @import("HistoryRequest.zig");
const SubmissionCapture = @import("SubmissionCapture.zig");
const HistoryHandler = @import("HistoryHandler.zig");
const std = @import("std");
const HistoryScope = @import("telar-core").HistoryScope;
const PaneIdType = @import("telar-core").PaneId;
const max_history_query_bytes = @import("telar-core").max_history_query_bytes;
const max_cwd_bytes_module = @import("telar-core").max_cwd_bytes;
const max_history_results = @import("telar-core").max_history_results;

fn testingRequest() HistoryRequest {
    return .{
        .request_id = @enumFromInt(11),
        .origin = .{
            .client = .{ .id = 7, .generation = 8 },
            .close_after_reply = true,
        },
        .text = "git",
        .scope = .workspace,
        .scope_value = "/work",
        .pane_id = .invalid,
        .failed_only = true,
        .author = .all,
        .match = .fts,
        .distinct = false,
        .limit = 12,
    };
}

test "Handler submits an owned query with its asynchronous reply origin" {
    var capture: SubmissionCapture = .{};
    var handler: HistoryHandler = .{ .service = capture.port() };
    var text = [_]u8{ 'g', 'i', 't' };
    var scope = [_]u8{ '/', 'w', 'o', 'r', 'k' };
    var request = testingRequest();
    request.text = &text;
    request.scope_value = &scope;

    try handler.executor().execute(request);
    @memset(&text, 'x');
    @memset(&scope, 'y');

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(request.request_id, capture.query.request_id);
    try std.testing.expectEqualDeep(request.origin, capture.query.origin);
    try std.testing.expectEqualStrings("git", capture.query.textSlice());
    try std.testing.expectEqual(HistoryScope.workspace, capture.query.scope);
    try std.testing.expectEqualStrings("/work", capture.query.scopeSlice());
    try std.testing.expectEqual(PaneIdType.invalid, capture.query.pane_id);
    try std.testing.expect(capture.query.failed_only);
    try std.testing.expectEqual(@as(u16, 12), capture.query.limit);
}

test "Handler reports bounded service backpressure after one submission" {
    var capture: SubmissionCapture = .{ .accepted = false };
    var handler: HistoryHandler = .{ .service = capture.port() };

    try std.testing.expectError(error.HistoryQueueFull, handler.execute(testingRequest()));

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
}

test "Handler rejects every model constraint before service submission" {
    var capture: SubmissionCapture = .{};
    var handler: HistoryHandler = .{ .service = capture.port() };
    const long_text = [_]u8{'q'} ** (max_history_query_bytes + 1);
    const long_scope = [_]u8{'s'} ** (max_cwd_bytes_module + 1);
    var invalid = [_]HistoryRequest{
        testingRequest(),
        testingRequest(),
        testingRequest(),
        testingRequest(),
        testingRequest(),
        testingRequest(),
    };
    invalid[0].text = &long_text;
    invalid[1].scope_value = &long_scope;
    invalid[2].limit = 0;
    invalid[3].limit = max_history_results + 1;
    invalid[4].scope = .pane;
    invalid[4].pane_id = .invalid;
    invalid[5].scope = .global;
    invalid[5].pane_id = @enumFromInt(4);

    for (invalid) |request| {
        try std.testing.expectError(error.InvalidHistoryQuery, handler.execute(request));
    }

    try std.testing.expectEqual(@as(usize, 0), capture.calls);
}
