//! Vertical contract tests for the runtime workspace-snapshot flow.

const StateType = @import("../../workspace/State.zig");
const RepositoryType = @import("../../workspace/Repository.zig");
const std = @import("std");
const WorkspaceSnapshotHandler = @import("../application/queries/WorkspaceSnapshotHandler.zig");
const ResponseQueueType = @import("../delivery/ResponseQueue.zig");
const WorkspaceSnapshotController = @import("../entrypoints/requests/WorkspaceSnapshotController.zig");
const RequestIdType = @import("telar-core").RequestId;

test "an aggregate crosses workspace query and controller boundaries" {
    var state: StateType = .{};
    var workspaces = RepositoryType.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location.workspace;
    var handler: WorkspaceSnapshotHandler = .{ .workspaces = workspaces.reader() };
    var responses: ResponseQueueType = .{};
    var controller = WorkspaceSnapshotController.init(&responses, handler.executor());
    const request_id: RequestIdType = @enumFromInt(41);

    try controller.requestWorkspaceSnapshot(.{
        .request_id = request_id,
        .workspace = location,
    });

    const response = responses.peek().?;
    try std.testing.expect(response.* == .workspace_snapshot);
    try std.testing.expectEqual(request_id, response.workspace_snapshot.request_id);
    try std.testing.expectEqualDeep(location, response.workspace_snapshot.workspace);
}
