//! Application use case for reconciling the runtime workspace-list replica.

const std = @import("std");
const client_model = @import("../model.zig");
const workspace_list = @import("../../workspace/root.zig").workspace_list;

pub const ReconcileWorkspaceListHandler = struct {
    model: *client_model.Model,

    /// Stores one decoded domain snapshot without deciding presentation.
    ///
    /// ```zig
    /// const commit = try handler.execute(snapshot) orelse return;
    /// ```
    pub fn execute(handler: *ReconcileWorkspaceListHandler, snapshot: workspace_list.SnapshotInput) !?client_model.WorkspaceListCommit {
        return handler.model.reconcileWorkspaceList(snapshot);
    }
};

test "ReconcileWorkspaceListHandler commits only newer runtime state" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var handler: ReconcileWorkspaceListHandler = .{ .model = &model };
    const entries = [_]workspace_list.EntryInput{
        .{ .workspace = @enumFromInt(1), .name = "telar", .path = "/work/telar", .tab_count = 2 },
        .{ .workspace = @enumFromInt(2), .name = "api", .path = "/work/api", .tab_count = 1 },
    };

    const commit = (try handler.execute(.{ .revision = 7, .entries = &entries })).?;

    try std.testing.expectEqual(@as(u64, 7), commit.runtime_revision);
    try std.testing.expectEqual(@as(usize, 2), commit.count);
    try std.testing.expectEqual(@as(u64, 1), commit.workspace_list_revision);
    try std.testing.expect(model.knowsWorkspace(@enumFromInt(2)));
    try std.testing.expectEqual(client_model.Version{ .workspace_list = 1 }, model.version());
    try std.testing.expect((try handler.execute(.{ .revision = 7, .entries = &entries })) == null);
    try std.testing.expectEqual(client_model.Version{ .workspace_list = 1 }, model.version());
}
