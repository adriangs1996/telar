//! Request-scoped controller for the create-workspace protocol message.

const std = @import("std");
const core = @import("telar-core");
const create_workspace_commands = @import("../commands/create_workspace.zig");
const response_queue = @import("../response_queue.zig");
const workspace_mod = @import("../../workspace/root.zig");

const schema = core.schema;
const ResponseQueue = response_queue.ResponseQueue;

pub const Controller = struct {
    responses: *ResponseQueue,
    create_workspace: create_workspace_commands.CreateWorkspaceExecutor,

    /// Creates a controller scoped to one create-workspace request.
    ///
    /// ```zig
    /// var controller = Controller.init(&responses, handler.executor());
    /// ```
    pub fn init(responses: *ResponseQueue, create_workspace: create_workspace_commands.CreateWorkspaceExecutor) Controller {
        return .{ .responses = responses, .create_workspace = create_workspace };
    }

    /// Maps the wire request into a creation transaction and queues its root
    /// pane confirmation or one expected protocol failure.
    ///
    /// ```zig
    /// try controller.createWorkspace(request);
    /// ```
    pub fn createWorkspace(controller: *Controller, request: schema.CreateWorkspaceView) !void {
        const result = controller.create_workspace.execute(.{
            .name = request.name,
            .size = request.size,
            .launch = request.launch,
        }) catch |err| {
            const failure: Failure = switch (err) {
                error.InvalidLaunchCwd => .{ .code = .invalid_request, .message = "cwd source pane is unavailable" },
                error.WorkspaceCreateFailed => .{ .code = .resource_limit, .message = "could not create workspace" },
                error.GeometryUnavailable => .{ .code = .resource_limit, .message = "workspace geometry is unavailable" },
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
            .pane_id = result.root_pane_id,
            .location = result.created.location,
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

const StubCreateWorkspace = struct {
    result: ?create_workspace_commands.CreateWorkspaceResult = null,
    failure: ?anyerror = null,
    call_count: usize = 0,
    last_size: ?schema.TerminalSize = null,
    last_name: [schema.max_workspace_name_bytes]u8 = undefined,
    last_name_len: usize = 0,
    last_cwd: [schema.max_cwd_bytes]u8 = undefined,
    last_cwd_len: usize = 0,
    last_cwd_source: ?schema.PaneId = null,
    last_environment_mode: schema.EnvironmentMode = .inherit_runtime,

    fn executor(stub: *StubCreateWorkspace) create_workspace_commands.CreateWorkspaceExecutor {
        return .{ .context = stub, .execute_fn = execute };
    }

    fn execute(context: *anyopaque, command: create_workspace_commands.CreateWorkspace) !create_workspace_commands.CreateWorkspaceResult {
        const stub: *StubCreateWorkspace = @ptrCast(@alignCast(context));
        std.debug.assert(command.name.len <= stub.last_name.len);
        std.debug.assert(command.launch.cwd.len <= stub.last_cwd.len);

        stub.call_count += 1;
        stub.last_size = command.size;
        stub.last_name_len = command.name.len;
        @memcpy(stub.last_name[0..command.name.len], command.name);
        stub.last_cwd_len = command.launch.cwd.len;
        @memcpy(stub.last_cwd[0..command.launch.cwd.len], command.launch.cwd);
        stub.last_cwd_source = command.launch.cwd_source;
        stub.last_environment_mode = command.launch.environment_mode;

        if (stub.failure) |failure| {
            return failure;
        }

        return stub.result.?;
    }

    fn lastName(stub: *const StubCreateWorkspace) []const u8 {
        return stub.last_name[0..stub.last_name_len];
    }

    fn lastCwd(stub: *const StubCreateWorkspace) []const u8 {
        return stub.last_cwd[0..stub.last_cwd_len];
    }
};

fn testingLocation() !schema.TabLocation {
    return .{
        .workspace = .{ .workspace = try schema.id.workspace(3) },
        .tab_id = try schema.id.tab(7),
    };
}

fn testingRequest(request_id: schema.RequestId) !schema.CreateWorkspaceView {
    return .{
        .request_id = request_id,
        .name = "requested",
        .size = .{ .cols = 120, .rows = 40 },
        .launch = .{
            .cwd = "/requested",
            .cwd_source = try schema.id.pane(5),
            .argument_count = 1,
            .encoded_arguments = "\x07\x00/bin/sh",
            .environment_mode = .replace,
            .environment_count = 1,
            .encoded_environment = "\x04\x00TERM\x05\x00xterm",
        },
    };
}

test "Controller maps create-workspace input to a canonical pane confirmation" {
    const canonical_location = try testingLocation();
    const request_id: schema.RequestId = @enumFromInt(11);
    const pane_id = try schema.id.pane(17);
    var responses: ResponseQueue = .{};
    var stub: StubCreateWorkspace = .{ .result = .{
        .created = try workspace_mod.WorkspaceCreated.init(canonical_location, "canonical"),
        .root_pane_id = pane_id,
    } };
    var controller = Controller.init(&responses, stub.executor());

    try controller.createWorkspace(try testingRequest(request_id));

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expectEqualStrings("requested", stub.lastName());
    try std.testing.expectEqual(schema.TerminalSize{ .cols = 120, .rows = 40 }, stub.last_size.?);
    try std.testing.expectEqualStrings("/requested", stub.lastCwd());
    try std.testing.expectEqual(try schema.id.pane(5), stub.last_cwd_source.?);
    try std.testing.expectEqual(schema.EnvironmentMode.replace, stub.last_environment_mode);
    const response = responses.peek().?;
    try std.testing.expect(response.* == .pane_opened);
    try std.testing.expectEqual(request_id, response.pane_opened.request_id);
    try std.testing.expectEqual(pane_id, response.pane_opened.pane_id);
    try std.testing.expectEqualDeep(canonical_location, response.pane_opened.location);
    try std.testing.expect(response.pane_opened.created);
}

test "Controller maps every expected create-workspace failure" {
    const cases = [_]struct {
        command_error: anyerror,
        failure_code: schema.FailureCode,
        message: []const u8,
    }{
        .{ .command_error = error.InvalidLaunchCwd, .failure_code = .invalid_request, .message = "cwd source pane is unavailable" },
        .{ .command_error = error.WorkspaceCreateFailed, .failure_code = .resource_limit, .message = "could not create workspace" },
        .{ .command_error = error.GeometryUnavailable, .failure_code = .resource_limit, .message = "workspace geometry is unavailable" },
        .{ .command_error = error.PaneLimitReached, .failure_code = .resource_limit, .message = "pane limit reached" },
        .{ .command_error = error.UnsupportedEnvironment, .failure_code = .invalid_request, .message = "custom pane environment is not supported" },
        .{ .command_error = error.PaneSpawnFailed, .failure_code = .spawn_failed, .message = "could not start pane process" },
    };

    for (cases, 0..) |case, index| {
        var responses: ResponseQueue = .{};
        var stub: StubCreateWorkspace = .{ .failure = case.command_error };
        var controller = Controller.init(&responses, stub.executor());
        const request_id: schema.RequestId = @enumFromInt(index + 20);

        try controller.createWorkspace(try testingRequest(request_id));

        const response = responses.peek().?;
        try std.testing.expect(response.* == .request_failed);
        try std.testing.expectEqual(request_id, response.request_failed.request_id);
        try std.testing.expectEqual(case.failure_code, response.request_failed.code);
        try std.testing.expectEqualStrings(case.message, response.request_failed.message);
    }
}

test "Controller propagates unexpected create-workspace failures" {
    var responses: ResponseQueue = .{};
    var stub: StubCreateWorkspace = .{ .failure = error.AttachmentUnavailable };
    var controller = Controller.init(&responses, stub.executor());

    try std.testing.expectError(error.AttachmentUnavailable, controller.createWorkspace(
        try testingRequest(@enumFromInt(30)),
    ));

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expect(responses.peek() == null);
}
