//! Vertical contract tests for the runtime workspace-snapshot flow.

const std = @import("std");
const core = @import("telar-core");
const workspace_snapshot_query = @import("../queries/workspace_snapshot.zig");
const workspace_snapshot_controller = @import("../controllers/workspace_snapshot.zig");
const delivery_mod = @import("../delivery/root.zig");
const workspace_mod = @import("../../workspace/root.zig");

const schema = core.schema;

test "an aggregate crosses workspace query and controller boundaries" {
    var state: workspace_mod.State = .{};
    var workspaces = workspace_mod.Repository.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location.workspace;
    var handler: workspace_snapshot_query.Handler = .{ .workspaces = workspaces.reader() };
    var responses: delivery_mod.ResponseQueue = .{};
    var controller = workspace_snapshot_controller.Controller.init(&responses, handler.executor());
    const request_id: schema.RequestId = @enumFromInt(41);

    try controller.requestWorkspaceSnapshot(.{
        .request_id = request_id,
        .workspace = location,
    });

    const response = responses.peek().?;
    try std.testing.expect(response.* == .workspace_snapshot);
    try std.testing.expectEqual(request_id, response.workspace_snapshot.request_id);
    try std.testing.expectEqualDeep(location, response.workspace_snapshot.workspace);
}
