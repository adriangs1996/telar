//! Request-scoped controller for the create-tab protocol message.

const std = @import("std");
const core = @import("telar-core");
const create_tab_commands = @import("../commands/create_tab.zig");
const response_queue = @import("../response_queue.zig");
const workspace_mod = @import("../../workspace/root.zig");

const schema = core.schema;
const PendingTabCreated = response_queue.PendingTabCreated;
const ResponseQueue = response_queue.ResponseQueue;

pub const Controller = struct {
    responses: *ResponseQueue,
    create_tab: create_tab_commands.CreateTabExecutor,

    /// Creates one controller for the lifetime of a create-tab request.
    ///
    /// ```zig
    /// var controller = Controller.init(&responses, handler.executor());
    /// ```
    pub fn init(responses: *ResponseQueue, create_tab: create_tab_commands.CreateTabExecutor) Controller {
        return .{ .responses = responses, .create_tab = create_tab };
    }

    /// Translates the wire request into an application command and maps its
    /// result or expected failure into exactly one client response.
    ///
    /// ```zig
    /// try controller.createTab(request);
    /// ```
    pub fn createTab(controller: *Controller, request: schema.CreateTabView) !void {
        const result = controller.create_tab.execute(.{
            .workspace = request.workspace,
            .label = request.label,
            .size = request.size,
            .launch = request.launch,
        }) catch |err| {
            const failure: Failure = switch (err) {
                error.WorkspaceNotFound => .{ .code = .workspace_not_found, .message = "workspace not found" },
                error.TabLimitReached => .{ .code = .resource_limit, .message = "tab limit reached" },
                error.InvalidTabLabel => .{ .code = .invalid_request, .message = "invalid tab label" },
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

        const label = result.created.labelSlice();
        var pending: PendingTabCreated = .{
            .request_id = request.request_id,
            .location = result.created.location,
            .position = result.created.position,
            .label = undefined,
            .label_len = @intCast(label.len),
            .root_pane_id = result.root_pane_id,
        };
        @memcpy(pending.label[0..label.len], label);
        try controller.responses.push(.{ .tab_created = pending });
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

const StubCreateTab = struct {
    result: ?create_tab_commands.CreateTabResult = null,
    failure: ?anyerror = null,
    call_count: usize = 0,
    last_workspace: ?schema.WorkspaceLocation = null,
    last_size: ?schema.TerminalSize = null,
    last_label: [schema.max_tab_label_bytes]u8 = undefined,
    last_label_len: usize = 0,
    last_cwd: [schema.max_cwd_bytes]u8 = undefined,
    last_cwd_len: usize = 0,
    last_cwd_source: ?schema.PaneId = null,
    last_argument_count: u16 = 0,
    last_environment_mode: schema.EnvironmentMode = .inherit_runtime,

    fn executor(stub: *StubCreateTab) create_tab_commands.CreateTabExecutor {
        return .{ .context = stub, .execute_fn = execute };
    }

    fn execute(context: *anyopaque, command: create_tab_commands.CreateTab) !create_tab_commands.CreateTabResult {
        const stub: *StubCreateTab = @ptrCast(@alignCast(context));
        std.debug.assert(command.label.len <= stub.last_label.len);
        std.debug.assert(command.launch.cwd.len <= stub.last_cwd.len);

        stub.call_count += 1;
        stub.last_workspace = command.workspace;
        stub.last_size = command.size;
        stub.last_label_len = command.label.len;
        @memcpy(stub.last_label[0..command.label.len], command.label);
        stub.last_cwd_len = command.launch.cwd.len;
        @memcpy(stub.last_cwd[0..command.launch.cwd.len], command.launch.cwd);
        stub.last_cwd_source = command.launch.cwd_source;
        stub.last_argument_count = command.launch.argument_count;
        stub.last_environment_mode = command.launch.environment_mode;

        if (stub.failure) |failure| {
            return failure;
        }

        return stub.result.?;
    }

    fn lastLabel(stub: *const StubCreateTab) []const u8 {
        return stub.last_label[0..stub.last_label_len];
    }

    fn lastCwd(stub: *const StubCreateTab) []const u8 {
        return stub.last_cwd[0..stub.last_cwd_len];
    }
};

fn testingLocation(workspace_id: u64, tab_id: u64) !schema.TabLocation {
    return .{
        .workspace = .{ .workspace = try schema.id.workspace(workspace_id) },
        .tab_id = try schema.id.tab(tab_id),
    };
}

fn testingRequest(workspace: schema.WorkspaceLocation, request_id: schema.RequestId) !schema.CreateTabView {
    return .{
        .request_id = request_id,
        .workspace = workspace,
        .label = "requested",
        .size = .{ .cols = 120, .rows = 40 },
        .launch = .{
            .cwd = "/requested",
            .cwd_source = try schema.id.pane(5),
            .argument_count = 2,
            .encoded_arguments = "\x07\x00/bin/sh\x02\x00-l",
            .environment_mode = .replace,
            .environment_count = 1,
            .encoded_environment = "\x04\x00TERM\x05\x00xterm",
        },
    };
}

test "Controller maps create-tab input and queues the canonical result" {
    const requested_location = try testingLocation(3, 1);
    const canonical_location = try testingLocation(3, 2);
    const request_id: schema.RequestId = @enumFromInt(11);
    const root_pane_id = try schema.id.pane(17);
    var responses: ResponseQueue = .{};
    var stub: StubCreateTab = .{ .result = .{
        .created = try workspace_mod.TabCreated.init(canonical_location, 1, "canonical"),
        .root_pane_id = root_pane_id,
    } };
    var controller = Controller.init(&responses, stub.executor());

    try controller.createTab(try testingRequest(requested_location.workspace, request_id));

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expectEqualDeep(requested_location.workspace, stub.last_workspace.?);
    try std.testing.expectEqual(schema.TerminalSize{ .cols = 120, .rows = 40 }, stub.last_size.?);
    try std.testing.expectEqualStrings("requested", stub.lastLabel());
    try std.testing.expectEqualStrings("/requested", stub.lastCwd());
    try std.testing.expectEqual(try schema.id.pane(5), stub.last_cwd_source.?);
    try std.testing.expectEqual(@as(u16, 2), stub.last_argument_count);
    try std.testing.expectEqual(schema.EnvironmentMode.replace, stub.last_environment_mode);
    const response = responses.peek().?;
    try std.testing.expect(response.* == .tab_created);
    try std.testing.expectEqual(request_id, response.tab_created.request_id);
    try std.testing.expectEqualDeep(canonical_location, response.tab_created.location);
    try std.testing.expectEqual(@as(u16, 1), response.tab_created.position);
    try std.testing.expectEqualStrings("canonical", response.tab_created.labelSlice());
    try std.testing.expectEqual(root_pane_id, response.tab_created.root_pane_id);
}

test "Controller maps every expected create-tab command error" {
    const location = try testingLocation(3, 1);
    const cases = [_]struct {
        command_error: anyerror,
        failure_code: schema.FailureCode,
        message: []const u8,
    }{
        .{ .command_error = error.WorkspaceNotFound, .failure_code = .workspace_not_found, .message = "workspace not found" },
        .{ .command_error = error.TabLimitReached, .failure_code = .resource_limit, .message = "tab limit reached" },
        .{ .command_error = error.InvalidTabLabel, .failure_code = .invalid_request, .message = "invalid tab label" },
        .{ .command_error = error.GeometryUnavailable, .failure_code = .resource_limit, .message = "workspace geometry is leased by another client" },
        .{ .command_error = error.InvalidLaunchCwd, .failure_code = .invalid_request, .message = "cwd source pane is unavailable" },
        .{ .command_error = error.PaneLimitReached, .failure_code = .resource_limit, .message = "pane limit reached" },
        .{ .command_error = error.UnsupportedEnvironment, .failure_code = .invalid_request, .message = "custom pane environment is not supported" },
        .{ .command_error = error.PaneSpawnFailed, .failure_code = .spawn_failed, .message = "could not start pane process" },
    };

    for (cases, 0..) |case, index| {
        var responses: ResponseQueue = .{};
        var stub: StubCreateTab = .{ .failure = case.command_error };
        var controller = Controller.init(&responses, stub.executor());
        const request_id: schema.RequestId = @enumFromInt(index + 20);

        try controller.createTab(try testingRequest(location.workspace, request_id));

        try std.testing.expectEqual(@as(usize, 1), stub.call_count);
        const response = responses.peek().?;
        try std.testing.expect(response.* == .request_failed);
        try std.testing.expectEqual(request_id, response.request_failed.request_id);
        try std.testing.expectEqual(case.failure_code, response.request_failed.code);
        try std.testing.expectEqualStrings(case.message, response.request_failed.message);
    }
}

test "Controller propagates unexpected create-tab failures without a response" {
    const location = try testingLocation(3, 1);
    var responses: ResponseQueue = .{};
    var stub: StubCreateTab = .{ .failure = error.AttachmentUnavailable };
    var controller = Controller.init(&responses, stub.executor());

    try std.testing.expectError(error.AttachmentUnavailable, controller.createTab(try testingRequest(
        location.workspace,
        @enumFromInt(30),
    )));

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expect(responses.peek() == null);
}
