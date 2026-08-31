//! Request-scoped controller for the rename-workspace protocol message.

const std = @import("std");
const core = @import("telar-core");
const rename_workspace_commands = @import("../commands/rename_workspace.zig");
const delivery_mod = @import("../delivery/root.zig");

const schema = core.schema;
const ResponseQueue = delivery_mod.ResponseQueue;

pub const Controller = struct {
    responses: *ResponseQueue,
    rename_workspace: rename_workspace_commands.RenameWorkspaceExecutor,

    /// Creates a controller scoped to one workspace rename request.
    ///
    /// ```zig
    /// var controller = Controller.init(&responses, handler.executor());
    /// ```
    pub fn init(responses: *ResponseQueue, rename_workspace: rename_workspace_commands.RenameWorkspaceExecutor) Controller {
        return .{ .responses = responses, .rename_workspace = rename_workspace };
    }

    /// Maps a wire request into a rename command and queues the workspace
    /// snapshot reference or the same protocol failures as the legacy flow.
    ///
    /// ```zig
    /// try controller.renameWorkspace(request);
    /// ```
    pub fn renameWorkspace(controller: *Controller, request: schema.RenameWorkspace) !void {
        const renamed = controller.rename_workspace.execute(.{
            .location = request.workspace,
            .name = request.name,
        }) catch |err| {
            switch (err) {
                error.WorkspaceNotFound => try controller.queueFailure(request.request_id, .{
                    .code = .workspace_not_found,
                    .message = "workspace not found",
                }),
                error.InvalidWorkspaceName => try controller.queueFailure(request.request_id, .{
                    .code = .internal,
                    .message = "could not rename workspace",
                }),
                else => return err,
            }

            return;
        };

        try controller.responses.push(.{ .workspace_snapshot = .{
            .request_id = request.request_id,
            .workspace = renamed.location,
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

const StubRenameWorkspace = struct {
    result: ?rename_workspace_commands.RenameWorkspaceResult = null,
    failure: ?anyerror = null,
    call_count: usize = 0,
    last_location: ?schema.WorkspaceLocation = null,
    last_name: [schema.max_tab_label_bytes]u8 = undefined,
    last_name_len: u8 = 0,

    fn executor(stub: *StubRenameWorkspace) rename_workspace_commands.RenameWorkspaceExecutor {
        return .{ .context = stub, .execute_fn = execute };
    }

    fn execute(context: *anyopaque, command: rename_workspace_commands.RenameWorkspace) anyerror!rename_workspace_commands.RenameWorkspaceResult {
        const stub: *StubRenameWorkspace = @ptrCast(@alignCast(context));
        std.debug.assert(command.name.len <= stub.last_name.len);

        stub.call_count += 1;
        stub.last_location = command.location;
        stub.last_name_len = @intCast(command.name.len);
        @memcpy(stub.last_name[0..command.name.len], command.name);

        if (stub.failure) |failure| {
            return failure;
        }

        return stub.result.?;
    }

    fn lastName(stub: *const StubRenameWorkspace) []const u8 {
        return stub.last_name[0..stub.last_name_len];
    }
};

fn testingLocation() !schema.WorkspaceLocation {
    return .{ .workspace = try schema.id.workspace(3) };
}

test "Controller maps a workspace rename and queues its canonical snapshot reference" {
    const requested_location = try testingLocation();
    const canonical_location: schema.WorkspaceLocation = .{ .workspace = try schema.id.workspace(4) };
    var responses: ResponseQueue = .{};
    var rename_stub: StubRenameWorkspace = .{
        .result = try rename_workspace_commands.RenameWorkspaceResult.init(canonical_location, "canonical"),
    };
    var controller = Controller.init(&responses, rename_stub.executor());
    const request_id: schema.RequestId = @enumFromInt(11);

    try controller.renameWorkspace(.{
        .request_id = request_id,
        .workspace = requested_location,
        .name = "requested",
    });

    try std.testing.expectEqual(@as(usize, 1), rename_stub.call_count);
    try std.testing.expectEqualDeep(requested_location, rename_stub.last_location.?);
    try std.testing.expectEqualStrings("requested", rename_stub.lastName());
    const response = responses.peek().?;
    try std.testing.expect(response.* == .workspace_snapshot);
    try std.testing.expectEqual(request_id, response.workspace_snapshot.request_id);
    try std.testing.expectEqualDeep(canonical_location, response.workspace_snapshot.workspace);
}

test "Controller preserves legacy workspace rename error mapping" {
    const location = try testingLocation();
    const cases = [_]struct {
        command_error: anyerror,
        failure_code: schema.FailureCode,
        message: []const u8,
    }{
        .{ .command_error = error.WorkspaceNotFound, .failure_code = .workspace_not_found, .message = "workspace not found" },
        .{ .command_error = error.InvalidWorkspaceName, .failure_code = .internal, .message = "could not rename workspace" },
    };

    for (cases, 0..) |case, index| {
        var responses: ResponseQueue = .{};
        var rename_stub: StubRenameWorkspace = .{ .failure = case.command_error };
        var controller = Controller.init(&responses, rename_stub.executor());
        const request_id: schema.RequestId = @enumFromInt(index + 20);

        try controller.renameWorkspace(.{
            .request_id = request_id,
            .workspace = location,
            .name = "requested",
        });

        const response = responses.peek().?;
        try std.testing.expect(response.* == .request_failed);
        try std.testing.expectEqual(request_id, response.request_failed.request_id);
        try std.testing.expectEqual(case.failure_code, response.request_failed.code);
        try std.testing.expectEqualStrings(case.message, response.request_failed.message);
    }
}

test "Controller propagates unexpected workspace rename failures" {
    var responses: ResponseQueue = .{};
    var rename_stub: StubRenameWorkspace = .{ .failure = error.EventPublisherUnavailable };
    var controller = Controller.init(&responses, rename_stub.executor());

    try std.testing.expectError(error.EventPublisherUnavailable, controller.renameWorkspace(.{
        .request_id = @enumFromInt(30),
        .workspace = try testingLocation(),
        .name = "requested",
    }));

    try std.testing.expectEqual(@as(usize, 1), rename_stub.call_count);
    try std.testing.expect(responses.peek() == null);
}
