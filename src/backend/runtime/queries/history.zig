//! Application boundary for submitting owned history queries.

const std = @import("std");
const history_mod = @import("../../history/root.zig");

const Query = history_mod.Query;
const QueryOrigin = history_mod.model.QueryOrigin;
const schema = history_mod.model.schema;

pub const Request = struct {
    request_id: schema.RequestId,
    origin: QueryOrigin,
    text: []const u8,
    scope: history_mod.model.Scope,
    scope_value: []const u8,
    pane_id: schema.PaneId,
    failed_only: bool,
    limit: u16,
};

pub const ServicePort = struct {
    context: *anyopaque,
    submit_fn: *const fn (*anyopaque, Query) bool,

    /// Transfers an owned query to the bounded history service. A false result
    /// means the service rejected it and retains responsibility for cleanup.
    ///
    /// ```zig
    /// const queued = service.submit(query);
    /// ```
    pub fn submit(service: ServicePort, query: Query) bool {
        return service.submit_fn(service.context, query);
    }
};

pub const Executor = struct {
    context: *anyopaque,
    execute_fn: *const fn (*anyopaque, Request) anyerror!void,

    /// Validates, owns, and submits one application-level history request.
    ///
    /// ```zig
    /// try executor.execute(request);
    /// ```
    pub fn execute(executor: Executor, request: Request) !void {
        return executor.execute_fn(executor.context, request);
    }
};

pub const Handler = struct {
    service: ServicePort,

    /// Copies all borrowed request bytes before attempting bounded submission.
    /// Invalid values and service backpressure have distinct application
    /// errors; the eventual history result is handled asynchronously.
    ///
    /// ```zig
    /// try handler.execute(request);
    /// ```
    pub fn execute(handler: *Handler, request: Request) !void {
        const query = Query.init(.{
            .request_id = request.request_id,
            .origin = request.origin,
            .text = request.text,
            .scope = request.scope,
            .scope_value = request.scope_value,
            .pane_id = request.pane_id,
            .failed_only = request.failed_only,
            .limit = request.limit,
        }) catch {
            return error.InvalidHistoryQuery;
        };

        if (!handler.service.submit(query)) {
            return error.HistoryQueueFull;
        }
    }

    /// Exposes this handler through the query interface used by controllers.
    ///
    /// ```zig
    /// const executor = handler.executor();
    /// ```
    pub fn executor(handler: *Handler) Executor {
        return .{ .context = handler, .execute_fn = executeErased };
    }

    fn executeErased(context: *anyopaque, request: Request) !void {
        const handler: *Handler = @ptrCast(@alignCast(context));
        return handler.execute(request);
    }
};

const SubmissionCapture = struct {
    accepted: bool = true,
    calls: usize = 0,
    query: Query = undefined,

    fn port(capture: *SubmissionCapture) ServicePort {
        return .{ .context = capture, .submit_fn = submit };
    }

    fn submit(context: *anyopaque, query: Query) bool {
        const capture: *SubmissionCapture = @ptrCast(@alignCast(context));
        capture.calls += 1;
        capture.query = query;
        return capture.accepted;
    }
};

fn testingRequest() Request {
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
        .limit = 12,
    };
}

test "Handler submits an owned query with its asynchronous reply origin" {
    var capture: SubmissionCapture = .{};
    var handler: Handler = .{ .service = capture.port() };
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
    try std.testing.expectEqual(history_mod.model.Scope.workspace, capture.query.scope);
    try std.testing.expectEqualStrings("/work", capture.query.scopeSlice());
    try std.testing.expectEqual(schema.PaneId.invalid, capture.query.pane_id);
    try std.testing.expect(capture.query.failed_only);
    try std.testing.expectEqual(@as(u16, 12), capture.query.limit);
}

test "Handler reports bounded service backpressure after one submission" {
    var capture: SubmissionCapture = .{ .accepted = false };
    var handler: Handler = .{ .service = capture.port() };

    try std.testing.expectError(error.HistoryQueueFull, handler.execute(testingRequest()));

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
}

test "Handler rejects every model constraint before service submission" {
    var capture: SubmissionCapture = .{};
    var handler: Handler = .{ .service = capture.port() };
    const long_text = [_]u8{'q'} ** (history_mod.model.max_query_bytes + 1);
    const long_scope = [_]u8{'s'} ** (schema.max_cwd_bytes + 1);
    var invalid = [_]Request{
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
    invalid[3].limit = history_mod.model.max_results + 1;
    invalid[4].scope = .pane;
    invalid[4].pane_id = .invalid;
    invalid[5].scope = .global;
    invalid[5].pane_id = @enumFromInt(4);

    for (invalid) |request| {
        try std.testing.expectError(error.InvalidHistoryQuery, handler.execute(request));
    }

    try std.testing.expectEqual(@as(usize, 0), capture.calls);
}
