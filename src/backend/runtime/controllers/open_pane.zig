//! Request-scoped controller for the open-pane protocol message.

const std = @import("std");
const core = @import("telar-core");
const open_pane_commands = @import("../commands/open_pane.zig");
const pane_mod = @import("../../pane/root.zig");
const delivery_mod = @import("../delivery/root.zig");

const schema = core.schema;
const ResponseQueue = delivery_mod.ResponseQueue;

pub const Controller = struct {
    responses: *ResponseQueue,
    open_pane: open_pane_commands.OpenPaneExecutor,

    /// Creates a controller scoped to one open-pane request.
    ///
    /// ```zig
    /// var controller = Controller.init(&responses, handler.executor());
    /// ```
    pub fn init(responses: *ResponseQueue, open_pane: open_pane_commands.OpenPaneExecutor) Controller {
        return .{ .responses = responses, .open_pane = open_pane };
    }

    /// Maps a wire request into pane selection or launch and queues its
    /// confirmation or one expected protocol failure.
    ///
    /// ```zig
    /// try controller.openPane(request);
    /// ```
    pub fn openPane(controller: *Controller, request: schema.OpenPaneView) !void {
        const result = controller.open_pane.execute(.{
            .target = request.target,
            .size = request.size,
            .launch = request.launch,
        }) catch |err| {
            const failure: Failure = switch (err) {
                error.PaneNotFound => .{ .code = .pane_not_found, .message = "pane not found" },
                error.WorkspaceNotFound => .{ .code = .workspace_not_found, .message = "workspace not found" },
                error.WorkspaceHasNoPane => .{ .code = .pane_not_found, .message = "workspace has no running pane" },
                error.InvalidOpenRequest => .{ .code = .invalid_request, .message = "default pane launch is missing" },
                error.InvalidLaunchCwd => .{ .code = .invalid_request, .message = "cwd source pane is unavailable" },
                error.WorkspaceCreateFailed => .{ .code = .resource_limit, .message = "could not create workspace" },
                error.GeometryUnavailable => .{ .code = .resource_limit, .message = "workspace geometry is leased by another client" },
                error.PaneLimitReached => .{ .code = .resource_limit, .message = "pane limit reached" },
                error.UnsupportedEnvironment => .{ .code = .invalid_request, .message = "custom pane environment is not supported" },
                error.PaneSpawnFailed => .{ .code = .spawn_failed, .message = "could not start pane process" },
                error.PaneResizeFailed => .{ .code = .internal, .message = "could not resize pane" },
                else => return err,
            };

            try controller.queueFailure(request.request_id, failure);
            return;
        };

        try controller.responses.push(.{ .pane_opened = .{
            .request_id = request.request_id,
            .pane_id = result.pane.key.id,
            .location = result.pane.location,
            .created = result.created,
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

const StubOpenPane = struct {
    result: ?open_pane_commands.OpenPaneResult = null,
    failure: ?anyerror = null,
    call_count: usize = 0,
    last_command: ?open_pane_commands.OpenPane = null,

    fn executor(stub: *StubOpenPane) open_pane_commands.OpenPaneExecutor {
        return .{ .context = stub, .execute_fn = execute };
    }

    fn execute(context: *anyopaque, command: open_pane_commands.OpenPane) anyerror!open_pane_commands.OpenPaneResult {
        const stub: *StubOpenPane = @ptrCast(@alignCast(context));
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

fn testingRequest(request_id: schema.RequestId) schema.OpenPaneView {
    return .{
        .request_id = request_id,
        .target = .default,
        .size = .{ .cols = 120, .rows = 40 },
        .launch = .{
            .cwd = "/requested",
            .argument_count = 1,
            .encoded_arguments = "\x07\x00/bin/sh",
            .environment_mode = .inherit_runtime,
            .environment_count = 0,
            .encoded_environment = "",
        },
    };
}

test "Controller maps open-pane input to the canonical result" {
    const request_id: schema.RequestId = @enumFromInt(11);
    const canonical_location = try testingLocation();
    const pane_id = try schema.id.pane(17);
    var responses: ResponseQueue = .{};
    var stub: StubOpenPane = .{ .result = .{
        .pane = .{
            .key = .{ .id = pane_id, .generation = 9 },
            .location = canonical_location,
        },
        .created = true,
    } };
    var controller = Controller.init(&responses, stub.executor());

    try controller.openPane(testingRequest(request_id));

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expect(stub.last_command.?.target == .default);
    try std.testing.expectEqual(schema.TerminalSize{ .cols = 120, .rows = 40 }, stub.last_command.?.size);
    try std.testing.expectEqualStrings("/requested", stub.last_command.?.launch.?.cwd);
    const response = responses.peek().?;
    try std.testing.expect(response.* == .pane_opened);
    try std.testing.expectEqual(request_id, response.pane_opened.request_id);
    try std.testing.expectEqual(pane_id, response.pane_opened.pane_id);
    try std.testing.expectEqualDeep(canonical_location, response.pane_opened.location);
    try std.testing.expect(response.pane_opened.created);
}

test "Controller maps every expected open-pane failure" {
    const cases = [_]struct {
        command_error: anyerror,
        failure_code: schema.FailureCode,
        message: []const u8,
    }{
        .{ .command_error = error.PaneNotFound, .failure_code = .pane_not_found, .message = "pane not found" },
        .{ .command_error = error.WorkspaceNotFound, .failure_code = .workspace_not_found, .message = "workspace not found" },
        .{ .command_error = error.WorkspaceHasNoPane, .failure_code = .pane_not_found, .message = "workspace has no running pane" },
        .{ .command_error = error.InvalidOpenRequest, .failure_code = .invalid_request, .message = "default pane launch is missing" },
        .{ .command_error = error.InvalidLaunchCwd, .failure_code = .invalid_request, .message = "cwd source pane is unavailable" },
        .{ .command_error = error.WorkspaceCreateFailed, .failure_code = .resource_limit, .message = "could not create workspace" },
        .{ .command_error = error.GeometryUnavailable, .failure_code = .resource_limit, .message = "workspace geometry is leased by another client" },
        .{ .command_error = error.PaneLimitReached, .failure_code = .resource_limit, .message = "pane limit reached" },
        .{ .command_error = error.UnsupportedEnvironment, .failure_code = .invalid_request, .message = "custom pane environment is not supported" },
        .{ .command_error = error.PaneSpawnFailed, .failure_code = .spawn_failed, .message = "could not start pane process" },
        .{ .command_error = error.PaneResizeFailed, .failure_code = .internal, .message = "could not resize pane" },
    };

    for (cases, 0..) |case, index| {
        var responses: ResponseQueue = .{};
        var stub: StubOpenPane = .{ .failure = case.command_error };
        var controller = Controller.init(&responses, stub.executor());
        const request_id: schema.RequestId = @enumFromInt(index + 20);

        try controller.openPane(testingRequest(request_id));

        const response = responses.peek().?;
        try std.testing.expect(response.* == .request_failed);
        try std.testing.expectEqual(request_id, response.request_failed.request_id);
        try std.testing.expectEqual(case.failure_code, response.request_failed.code);
        try std.testing.expectEqualStrings(case.message, response.request_failed.message);
    }
}

test "Controller propagates unexpected open-pane failures" {
    var responses: ResponseQueue = .{};
    var stub: StubOpenPane = .{ .failure = error.AttachmentUnavailable };
    var controller = Controller.init(&responses, stub.executor());

    try std.testing.expectError(error.AttachmentUnavailable, controller.openPane(
        testingRequest(@enumFromInt(40)),
    ));

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expect(responses.peek() == null);
}

test "Controller reports backpressure after a successful open" {
    const location = try testingLocation();
    var responses: ResponseQueue = .{};

    while (responses.len < responses.items.len) {
        try responses.push(.{ .tab_moved = .{
            .request_id = .none,
            .location = location,
            .position = 0,
        } });
    }

    var stub: StubOpenPane = .{ .result = .{
        .pane = .{
            .key = .{ .id = try schema.id.pane(17), .generation = 9 },
            .location = location,
        },
        .created = false,
    } };
    var controller = Controller.init(&responses, stub.executor());

    try std.testing.expectError(error.ResponseQueueFull, controller.openPane(
        testingRequest(@enumFromInt(41)),
    ));

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expectEqual(@as(u8, responses.items.len), responses.len);
}
