//! Request-scoped controller for the rename-workspace protocol message.

const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const workspace_module = @import("telar-core").workspace;
const ResponseQueue = @import("../../delivery/ResponseQueue.zig");
const StubRenameWorkspace = @import("StubRenameWorkspace.zig");
const WorkspaceRenamed = @import("../../../workspace/WorkspaceRenamed.zig");
const RenameWorkspaceController = @import("RenameWorkspaceController.zig");
const RequestIdType = @import("telar-core").RequestId;
const std = @import("std");
const FailureCodeType = @import("telar-core").FailureCode;

fn testingLocation() !WorkspaceLocationType {
    return .{ .workspace = try workspace_module(3) };
}

test "Controller maps a workspace rename and queues its canonical snapshot reference" {
    const requested_location = try testingLocation();
    const canonical_location: WorkspaceLocationType = .{ .workspace = try workspace_module(4) };
    var responses: ResponseQueue = .{};
    var rename_stub: StubRenameWorkspace = .{
        .result = try WorkspaceRenamed.init(canonical_location, "canonical"),
    };
    var controller = RenameWorkspaceController.init(&responses, rename_stub.executor());
    const request_id: RequestIdType = @enumFromInt(11);

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
        failure_code: FailureCodeType,
        message: []const u8,
    }{
        .{ .command_error = error.WorkspaceNotFound, .failure_code = .workspace_not_found, .message = "workspace not found" },
        .{ .command_error = error.InvalidWorkspaceName, .failure_code = .internal, .message = "could not rename workspace" },
    };

    for (cases, 0..) |case, index| {
        var responses: ResponseQueue = .{};
        var rename_stub: StubRenameWorkspace = .{ .failure = case.command_error };
        var controller = RenameWorkspaceController.init(&responses, rename_stub.executor());
        const request_id: RequestIdType = @enumFromInt(index + 20);

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
    var controller = RenameWorkspaceController.init(&responses, rename_stub.executor());

    try std.testing.expectError(error.EventPublisherUnavailable, controller.renameWorkspace(.{
        .request_id = @enumFromInt(30),
        .workspace = try testingLocation(),
        .name = "requested",
    }));

    try std.testing.expectEqual(@as(usize, 1), rename_stub.call_count);
    try std.testing.expect(responses.peek() == null);
}
