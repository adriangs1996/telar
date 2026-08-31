//! Request-scoped controller for the move-tab protocol message.

const std = @import("std");
const core = @import("telar-core");
const move_tab_commands = @import("../commands/move_tab.zig");
const delivery_mod = @import("../delivery/root.zig");

const schema = core.schema;
const ResponseQueue = delivery_mod.ResponseQueue;

pub const Controller = struct {
    responses: *ResponseQueue,
    move_tab: move_tab_commands.MoveTabExecutor,

    /// Creates a controller scoped to one runtime request.
    ///
    /// ```zig
    /// var controller = Controller.init(&responses, handler.executor());
    /// ```
    pub fn init(responses: *ResponseQueue, move_tab: move_tab_commands.MoveTabExecutor) Controller {
        return .{ .responses = responses, .move_tab = move_tab };
    }

    /// Maps the wire request into a command and returns either the canonical
    /// committed position or one expected protocol failure.
    ///
    /// ```zig
    /// try controller.moveTab(request);
    /// ```
    pub fn moveTab(controller: *Controller, request: schema.MoveTab) !void {
        const moved = controller.move_tab.execute(.{
            .location = request.location,
            .direction = request.direction,
        }) catch |err| {
            switch (err) {
                error.WorkspaceNotFound => try controller.queueFailure(request.request_id, .{
                    .code = .workspace_not_found,
                    .message = "workspace not found",
                }),
                error.TabNotFound => try controller.queueFailure(request.request_id, .{
                    .code = .tab_not_found,
                    .message = "tab not found",
                }),
                else => return err,
            }

            return;
        };

        try controller.responses.push(.{ .tab_moved = .{
            .request_id = request.request_id,
            .location = moved.location,
            .position = moved.position,
        } });
    }

    fn queueFailure(controller: *Controller, request_id: schema.RequestId, failure: Failure) !void {
        try controller.responses.push(.{ .request_failed = .{
            .request_id = request_id,
            .code = failure.code,
            .message = failure.message,
        } });
    }
};

const Failure = struct {
    code: schema.FailureCode,
    message: []const u8,
};

const StubMoveTab = struct {
    result: ?move_tab_commands.MoveTabResult = null,
    failure: ?anyerror = null,
    call_count: usize = 0,
    last_command: ?move_tab_commands.MoveTab = null,

    fn executor(stub: *StubMoveTab) move_tab_commands.MoveTabExecutor {
        return .{ .context = stub, .execute_fn = execute };
    }

    fn execute(context: *anyopaque, command: move_tab_commands.MoveTab) anyerror!move_tab_commands.MoveTabResult {
        const stub: *StubMoveTab = @ptrCast(@alignCast(context));
        stub.call_count += 1;
        stub.last_command = command;

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

test "Controller maps a move request and queues the canonical result" {
    const requested_location = try testingLocation();
    var canonical_location = requested_location;
    canonical_location.tab_id = try schema.id.tab(8);
    var responses: ResponseQueue = .{};
    var move_stub: StubMoveTab = .{
        .result = .{ .location = canonical_location, .position = 2 },
    };
    var controller = Controller.init(&responses, move_stub.executor());
    const request_id: schema.RequestId = @enumFromInt(11);

    try controller.moveTab(.{
        .request_id = request_id,
        .location = requested_location,
        .direction = .next,
    });

    try std.testing.expectEqual(@as(usize, 1), move_stub.call_count);
    try std.testing.expectEqualDeep(requested_location, move_stub.last_command.?.location);
    try std.testing.expectEqual(schema.TabMoveDirection.next, move_stub.last_command.?.direction);
    const response = responses.peek().?;
    try std.testing.expect(response.* == .tab_moved);
    try std.testing.expectEqual(request_id, response.tab_moved.request_id);
    try std.testing.expectEqualDeep(canonical_location, response.tab_moved.location);
    try std.testing.expectEqual(@as(u16, 2), response.tab_moved.position);
}

test "Controller maps expected move errors without a success response" {
    const location = try testingLocation();
    const cases = [_]struct {
        command_error: anyerror,
        failure_code: schema.FailureCode,
        message: []const u8,
    }{
        .{ .command_error = error.WorkspaceNotFound, .failure_code = .workspace_not_found, .message = "workspace not found" },
        .{ .command_error = error.TabNotFound, .failure_code = .tab_not_found, .message = "tab not found" },
    };

    for (cases, 0..) |case, index| {
        var responses: ResponseQueue = .{};
        var move_stub: StubMoveTab = .{ .failure = case.command_error };
        var controller = Controller.init(&responses, move_stub.executor());
        const request_id: schema.RequestId = @enumFromInt(index + 20);

        try controller.moveTab(.{
            .request_id = request_id,
            .location = location,
            .direction = .previous,
        });

        try std.testing.expectEqual(@as(usize, 1), move_stub.call_count);
        const response = responses.peek().?;
        try std.testing.expect(response.* == .request_failed);
        try std.testing.expectEqual(request_id, response.request_failed.request_id);
        try std.testing.expectEqual(case.failure_code, response.request_failed.code);
        try std.testing.expectEqualStrings(case.message, response.request_failed.message);
    }
}

test "Controller propagates unexpected move failures without a response" {
    var responses: ResponseQueue = .{};
    var move_stub: StubMoveTab = .{ .failure = error.EventPublisherUnavailable };
    var controller = Controller.init(&responses, move_stub.executor());

    try std.testing.expectError(error.EventPublisherUnavailable, controller.moveTab(.{
        .request_id = @enumFromInt(30),
        .location = try testingLocation(),
        .direction = .next,
    }));

    try std.testing.expectEqual(@as(usize, 1), move_stub.call_count);
    try std.testing.expect(responses.peek() == null);
}
