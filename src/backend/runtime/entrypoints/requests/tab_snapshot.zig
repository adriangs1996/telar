//! Request-scoped controller for tab-snapshot protocol messages.

const std = @import("std");
const core = @import("telar-core");
const tab_snapshot_query = @import("../../application/queries/tab_snapshot.zig");
const delivery_mod = @import("../../delivery/root.zig");

const schema = core.schema;
const ResponseQueue = delivery_mod.ResponseQueue;

pub const Controller = struct {
    responses: *ResponseQueue,
    query: tab_snapshot_query.Executor,

    /// Creates a controller scoped to one tab-snapshot request.
    ///
    /// ```zig
    /// var controller = Controller.init(&responses, handler.executor());
    /// ```
    pub fn init(responses: *ResponseQueue, query: tab_snapshot_query.Executor) Controller {
        return .{ .responses = responses, .query = query };
    }

    /// Maps a wire request to the tab query and queues its canonical response
    /// or a `tab_not_found` failure.
    ///
    /// ```zig
    /// try controller.requestTabSnapshot(request);
    /// ```
    pub fn requestTabSnapshot(controller: *Controller, request: schema.RequestTabSnapshot) !void {
        const snapshot = controller.query.execute(.{ .location = request.location }) catch |err| {
            if (err == error.TabNotFound) {
                try controller.responses.push(.{ .request_failed = .{
                    .request_id = request.request_id,
                    .code = .tab_not_found,
                    .message = "tab not found",
                } });
                return;
            }

            return err;
        };

        try controller.responses.push(.{ .tab_snapshot = .{
            .request_id = request.request_id,
            .location = snapshot.location,
        } });
    }
};

const StubQuery = struct {
    result: ?tab_snapshot_query.Result = null,
    failure: ?anyerror = null,
    call_count: usize = 0,
    last_request: ?tab_snapshot_query.Request = null,

    fn executor(stub: *StubQuery) tab_snapshot_query.Executor {
        return .{ .context = stub, .execute_fn = execute };
    }

    fn execute(context: *anyopaque, request: tab_snapshot_query.Request) anyerror!tab_snapshot_query.Result {
        const stub: *StubQuery = @ptrCast(@alignCast(context));
        stub.call_count += 1;
        stub.last_request = request;

        if (stub.failure) |failure| {
            return failure;
        }

        return stub.result.?;
    }
};

fn testingLocation() !schema.TabLocation {
    return .{
        .workspace = .{ .workspace = try schema.id.workspace(3) },
        .tab_id = try schema.id.tab(7),
    };
}

test "Controller maps a tab snapshot request to its canonical result" {
    const requested_location = try testingLocation();
    var canonical_location = requested_location;
    canonical_location.tab_id = try schema.id.tab(8);
    var responses: ResponseQueue = .{};
    var query_stub: StubQuery = .{
        .result = .{ .location = canonical_location },
    };
    var controller = Controller.init(&responses, query_stub.executor());
    const request_id: schema.RequestId = @enumFromInt(11);

    try controller.requestTabSnapshot(.{
        .request_id = request_id,
        .location = requested_location,
    });

    try std.testing.expectEqual(@as(usize, 1), query_stub.call_count);
    try std.testing.expectEqualDeep(requested_location, query_stub.last_request.?.location);
    const response = responses.peek().?;
    try std.testing.expect(response.* == .tab_snapshot);
    try std.testing.expectEqual(request_id, response.tab_snapshot.request_id);
    try std.testing.expectEqualDeep(canonical_location, response.tab_snapshot.location);
}

test "Controller maps a missing tab to one protocol failure" {
    var responses: ResponseQueue = .{};
    var query_stub: StubQuery = .{ .failure = error.TabNotFound };
    var controller = Controller.init(&responses, query_stub.executor());
    const request_id: schema.RequestId = @enumFromInt(20);

    try controller.requestTabSnapshot(.{
        .request_id = request_id,
        .location = try testingLocation(),
    });

    try std.testing.expectEqual(@as(usize, 1), query_stub.call_count);
    const response = responses.peek().?;
    try std.testing.expect(response.* == .request_failed);
    try std.testing.expectEqual(request_id, response.request_failed.request_id);
    try std.testing.expectEqual(schema.FailureCode.tab_not_found, response.request_failed.code);
    try std.testing.expectEqualStrings("tab not found", response.request_failed.message);
}

test "Controller propagates unexpected query failures without a response" {
    var responses: ResponseQueue = .{};
    var query_stub: StubQuery = .{ .failure = error.QuerySourceUnavailable };
    var controller = Controller.init(&responses, query_stub.executor());

    try std.testing.expectError(error.QuerySourceUnavailable, controller.requestTabSnapshot(.{
        .request_id = @enumFromInt(30),
        .location = try testingLocation(),
    }));

    try std.testing.expectEqual(@as(usize, 1), query_stub.call_count);
    try std.testing.expect(responses.peek() == null);
}

test "Controller reports response backpressure after a successful query" {
    const location = try testingLocation();
    var responses: ResponseQueue = .{};

    while (responses.len < responses.items.len) {
        try responses.push(.{ .tab_moved = .{
            .request_id = .none,
            .location = location,
            .position = 0,
        } });
    }

    var query_stub: StubQuery = .{ .result = .{ .location = location } };
    var controller = Controller.init(&responses, query_stub.executor());

    try std.testing.expectError(error.ResponseQueueFull, controller.requestTabSnapshot(.{
        .request_id = @enumFromInt(31),
        .location = location,
    }));

    try std.testing.expectEqual(@as(usize, 1), query_stub.call_count);
    try std.testing.expectEqual(@as(u8, responses.items.len), responses.len);
}
