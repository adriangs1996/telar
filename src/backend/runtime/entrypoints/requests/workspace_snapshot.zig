//! Request-scoped controller for workspace-snapshot protocol messages.

const std = @import("std");
const core = @import("telar-core");
const workspace_snapshot_query = @import("../../application/queries/workspace_snapshot.zig");
const delivery_mod = @import("../../delivery/root.zig");

const schema = core.schema;
const ResponseQueue = delivery_mod.ResponseQueue;

pub const Controller = struct {
    responses: *ResponseQueue,
    query: workspace_snapshot_query.Executor,

    /// Creates a controller scoped to one workspace-snapshot request.
    ///
    /// ```zig
    /// var controller = Controller.init(&responses, handler.executor());
    /// ```
    pub fn init(responses: *ResponseQueue, query: workspace_snapshot_query.Executor) Controller {
        return .{ .responses = responses, .query = query };
    }

    /// Maps a wire request to the workspace query and queues its canonical
    /// reference or a `workspace_not_found` failure.
    ///
    /// ```zig
    /// try controller.requestWorkspaceSnapshot(request);
    /// ```
    pub fn requestWorkspaceSnapshot(controller: *Controller, request: schema.RequestWorkspaceSnapshot) !void {
        const snapshot = controller.query.execute(.{ .location = request.workspace }) catch |err| {
            if (err == error.WorkspaceNotFound) {
                try controller.responses.push(.{ .request_failed = .{
                    .request_id = request.request_id,
                    .code = .workspace_not_found,
                    .message = "workspace not found",
                } });
                return;
            }

            return err;
        };

        try controller.responses.push(.{ .workspace_snapshot = .{
            .request_id = request.request_id,
            .workspace = snapshot.location,
        } });
    }
};

const StubQuery = struct {
    result: ?workspace_snapshot_query.Result = null,
    failure: ?anyerror = null,
    call_count: usize = 0,
    last_request: ?workspace_snapshot_query.Request = null,

    fn executor(stub: *StubQuery) workspace_snapshot_query.Executor {
        return .{ .context = stub, .execute_fn = execute };
    }

    fn execute(context: *anyopaque, request: workspace_snapshot_query.Request) anyerror!workspace_snapshot_query.Result {
        const stub: *StubQuery = @ptrCast(@alignCast(context));
        stub.call_count += 1;
        stub.last_request = request;

        if (stub.failure) |failure| {
            return failure;
        }

        return stub.result.?;
    }
};

fn testingLocation() !schema.WorkspaceLocation {
    return .{ .workspace = try schema.id.workspace(3) };
}

test "Controller maps a workspace snapshot request to its canonical result" {
    const requested_location = try testingLocation();
    const canonical_location: schema.WorkspaceLocation = .{ .workspace = try schema.id.workspace(4) };
    var responses: ResponseQueue = .{};
    var query_stub: StubQuery = .{ .result = .{ .location = canonical_location } };
    var controller = Controller.init(&responses, query_stub.executor());
    const request_id: schema.RequestId = @enumFromInt(11);

    try controller.requestWorkspaceSnapshot(.{
        .request_id = request_id,
        .workspace = requested_location,
    });

    try std.testing.expectEqual(@as(usize, 1), query_stub.call_count);
    try std.testing.expectEqualDeep(requested_location, query_stub.last_request.?.location);
    const response = responses.peek().?;
    try std.testing.expect(response.* == .workspace_snapshot);
    try std.testing.expectEqual(request_id, response.workspace_snapshot.request_id);
    try std.testing.expectEqualDeep(canonical_location, response.workspace_snapshot.workspace);
}

test "Controller maps a missing workspace to one protocol failure" {
    var responses: ResponseQueue = .{};
    var query_stub: StubQuery = .{ .failure = error.WorkspaceNotFound };
    var controller = Controller.init(&responses, query_stub.executor());
    const request_id: schema.RequestId = @enumFromInt(20);

    try controller.requestWorkspaceSnapshot(.{
        .request_id = request_id,
        .workspace = try testingLocation(),
    });

    const response = responses.peek().?;
    try std.testing.expect(response.* == .request_failed);
    try std.testing.expectEqual(request_id, response.request_failed.request_id);
    try std.testing.expectEqual(schema.FailureCode.workspace_not_found, response.request_failed.code);
    try std.testing.expectEqualStrings("workspace not found", response.request_failed.message);
}

test "Controller propagates unexpected workspace query failures" {
    var responses: ResponseQueue = .{};
    var query_stub: StubQuery = .{ .failure = error.QuerySourceUnavailable };
    var controller = Controller.init(&responses, query_stub.executor());

    try std.testing.expectError(error.QuerySourceUnavailable, controller.requestWorkspaceSnapshot(.{
        .request_id = @enumFromInt(30),
        .workspace = try testingLocation(),
    }));

    try std.testing.expectEqual(@as(usize, 1), query_stub.call_count);
    try std.testing.expect(responses.peek() == null);
}

test "Controller reports response backpressure after a successful workspace query" {
    const location = try testingLocation();
    var responses: ResponseQueue = .{};
    const tab_location: schema.TabLocation = .{
        .workspace = location,
        .tab_id = try schema.id.tab(1),
    };

    while (responses.len < responses.items.len) {
        try responses.push(.{ .tab_moved = .{
            .request_id = .none,
            .location = tab_location,
            .position = 0,
        } });
    }

    var query_stub: StubQuery = .{ .result = .{ .location = location } };
    var controller = Controller.init(&responses, query_stub.executor());

    try std.testing.expectError(error.ResponseQueueFull, controller.requestWorkspaceSnapshot(.{
        .request_id = @enumFromInt(31),
        .workspace = location,
    }));

    try std.testing.expectEqual(@as(usize, 1), query_stub.call_count);
    try std.testing.expectEqual(@as(u8, responses.items.len), responses.len);
}
