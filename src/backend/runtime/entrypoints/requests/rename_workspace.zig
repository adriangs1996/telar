//! Request-scoped controller for the rename-workspace protocol message.

const std = @import("std");
const core = @import("telar-core");
const rename_workspace_commands = @import("../../application/commands/rename_workspace.zig");
const delivery_mod = @import("../../delivery/root.zig");

pub const schema = core.schema;
pub const ResponseQueue = delivery_mod.ResponseQueue;

pub const Controller = @import("RenameWorkspaceController.zig");

const Failure = @import("RenameWorkspaceFailure.zig");

const StubRenameWorkspace = @import("StubRenameWorkspace.zig");

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
