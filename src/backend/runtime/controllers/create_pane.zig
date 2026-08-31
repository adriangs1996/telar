//! Request-scoped controller for the create-pane protocol message.

const std = @import("std");
const core = @import("telar-core");
const create_pane_commands = @import("../commands/create_pane.zig");
const pane_mod = @import("../../pane/root.zig");
const delivery_mod = @import("../delivery/root.zig");

const schema = core.schema;
const ResponseQueue = delivery_mod.ResponseQueue;

pub const Controller = struct {
    responses: *ResponseQueue,
    create_pane: create_pane_commands.CreatePaneExecutor,

    /// Creates a controller scoped to one create-pane request.
    ///
    /// ```zig
    /// var controller = Controller.init(&responses, handler.executor());
    /// ```
    pub fn init(responses: *ResponseQueue, create_pane: create_pane_commands.CreatePaneExecutor) Controller {
        return .{ .responses = responses, .create_pane = create_pane };
    }

    /// Maps a wire request into a pane launch and queues its confirmation or
    /// one expected protocol failure.
    ///
    /// ```zig
    /// try controller.createPane(request);
    /// ```
    pub fn createPane(controller: *Controller, request: schema.CreatePaneView) !void {
        const launched = controller.create_pane.execute(.{
            .location = request.location,
            .size = request.size,
            .launch = request.launch,
        }) catch |err| {
            const failure: Failure = switch (err) {
                error.TabNotFound => .{ .code = .pane_not_found, .message = "tab not found" },
                error.GeometryUnavailable => .{ .code = .resource_limit, .message = "workspace geometry is leased by another client" },
                error.InvalidLaunchCwd => .{ .code = .invalid_request, .message = "cwd source pane is unavailable" },
                error.PaneLimitReached => .{ .code = .resource_limit, .message = "pane limit reached" },
                error.UnsupportedEnvironment => .{ .code = .invalid_request, .message = "custom pane environment is not supported" },
                error.PaneSpawnFailed => .{ .code = .spawn_failed, .message = "could not start pane process" },
                else => return err,
            };

            try controller.queueFailure(request.request_id, failure);
            return;
        };

        try controller.responses.push(.{ .pane_opened = .{
            .request_id = request.request_id,
            .pane_id = launched.key.id,
            .location = launched.location,
            .created = true,
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

const StubCreatePane = struct {
    result: ?pane_mod.PaneLaunched = null,
    failure: ?anyerror = null,
    call_count: usize = 0,
    last_command: ?create_pane_commands.CreatePane = null,

    fn executor(stub: *StubCreatePane) create_pane_commands.CreatePaneExecutor {
        return .{ .context = stub, .execute_fn = execute };
    }

    fn execute(context: *anyopaque, command: create_pane_commands.CreatePane) anyerror!pane_mod.PaneLaunched {
        const stub: *StubCreatePane = @ptrCast(@alignCast(context));
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

fn testingRequest(request_id: schema.RequestId) !schema.CreatePaneView {
    return .{
        .request_id = request_id,
        .location = try testingLocation(),
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

test "Controller maps create-pane input to the canonical launch result" {
    const request_id: schema.RequestId = @enumFromInt(11);
    const canonical_location: schema.TabLocation = .{
        .workspace = .{ .workspace = try schema.id.workspace(4) },
        .tab_id = try schema.id.tab(8),
    };
    const pane_id = try schema.id.pane(17);
    var responses: ResponseQueue = .{};
    var stub: StubCreatePane = .{ .result = .{
        .key = .{ .id = pane_id, .generation = 9 },
        .location = canonical_location,
    } };
    var controller = Controller.init(&responses, stub.executor());

    try controller.createPane(try testingRequest(request_id));

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expectEqualDeep(try testingLocation(), stub.last_command.?.location);
    try std.testing.expectEqual(schema.TerminalSize{ .cols = 120, .rows = 40 }, stub.last_command.?.size);
    try std.testing.expectEqualStrings("/requested", stub.last_command.?.launch.cwd);
    const response = responses.peek().?;
    try std.testing.expect(response.* == .pane_opened);
    try std.testing.expectEqual(request_id, response.pane_opened.request_id);
    try std.testing.expectEqual(pane_id, response.pane_opened.pane_id);
    try std.testing.expectEqualDeep(canonical_location, response.pane_opened.location);
    try std.testing.expect(response.pane_opened.created);
}

test "Controller maps every expected create-pane failure" {
    const cases = [_]struct {
        command_error: anyerror,
        failure_code: schema.FailureCode,
        message: []const u8,
    }{
        .{ .command_error = error.TabNotFound, .failure_code = .pane_not_found, .message = "tab not found" },
        .{ .command_error = error.GeometryUnavailable, .failure_code = .resource_limit, .message = "workspace geometry is leased by another client" },
        .{ .command_error = error.InvalidLaunchCwd, .failure_code = .invalid_request, .message = "cwd source pane is unavailable" },
        .{ .command_error = error.PaneLimitReached, .failure_code = .resource_limit, .message = "pane limit reached" },
        .{ .command_error = error.UnsupportedEnvironment, .failure_code = .invalid_request, .message = "custom pane environment is not supported" },
        .{ .command_error = error.PaneSpawnFailed, .failure_code = .spawn_failed, .message = "could not start pane process" },
    };

    for (cases, 0..) |case, index| {
        var responses: ResponseQueue = .{};
        var stub: StubCreatePane = .{ .failure = case.command_error };
        var controller = Controller.init(&responses, stub.executor());
        const request_id: schema.RequestId = @enumFromInt(index + 20);

        try controller.createPane(try testingRequest(request_id));

        const response = responses.peek().?;
        try std.testing.expect(response.* == .request_failed);
        try std.testing.expectEqual(request_id, response.request_failed.request_id);
        try std.testing.expectEqual(case.failure_code, response.request_failed.code);
        try std.testing.expectEqualStrings(case.message, response.request_failed.message);
    }
}

test "Controller propagates post-launch attachment failures" {
    var responses: ResponseQueue = .{};
    var stub: StubCreatePane = .{ .failure = error.AttachmentUnavailable };
    var controller = Controller.init(&responses, stub.executor());

    try std.testing.expectError(error.AttachmentUnavailable, controller.createPane(
        try testingRequest(@enumFromInt(30)),
    ));

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expect(responses.peek() == null);
}
