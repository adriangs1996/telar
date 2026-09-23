//! The client leaves one workspace and arrives at another
//! (docs/flows/workspace-handoff.md).
const std = @import("std");
const ClientModel = @import("../state/ClientModel.zig");
const Panes = @import("../panes/Panes.zig");
const WorkspaceLayout = @import("WorkspaceLayout.zig");
const RootTab = @import("RootTab.zig");

/// Retires every tab and pane of the current workspace.
/// Example: `workspace_handoff.clear(model);`
pub fn clear(model: *ClientModel) void {
    model.panes.deinit();
    model.tabs.count = 0;
    model.tabs.active = 0;
    model.workspace = null;
    model.workspace_name_len = 0;
    model.pending_layout_restore = null;
}

/// Builds the arriving workspace's root tab before retiring the current
/// workspace, so failure preserves every tab and pane.
/// Example: `try workspace_handoff.replaceWithRoot(model, root);`
pub fn replaceWithRoot(model: *ClientModel, root: RootTab) !void {
    var layout: WorkspaceLayout = .{};
    _ = layout.setPaneGaps(model.pane_gaps);
    try layout.addRoot(root.pane_id);

    const pane = try Panes.create(
        model.gpa,
        .{
            .pane_id = root.pane_id,
            .location = root.location,
            .size = root.size,
        },
        true,
    );

    clear(model);
    model.panes.insert(pane);
    const slot = model.tabs.insert(0, root.location, model.pane_gaps);
    model.tabs.layout[slot] = layout;
    model.tabs.restore_display_order[slot] = true;
    model.tabs.active = slot;
    model.workspace = root.location.workspace;
}

/// Builds the first workspace of an empty client.
/// Example: `try workspace_handoff.bootstrap(model, root);`
pub fn bootstrap(model: *ClientModel, root: RootTab) !void {
    if (model.tabs.count != 0) {
        return error.ModelNotEmpty;
    }

    try replaceWithRoot(model, root);
}

test "a failed root construction keeps the previous workspace" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();

    try bootstrap(&model, .{
        .pane_id = @enumFromInt(1),
        .location = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(1) },
        .size = .{ .cols = 4, .rows = 2 },
    });

    try std.testing.expectError(error.InvalidPaneId, replaceWithRoot(&model, .{
        .pane_id = .invalid,
        .location = .{ .workspace = .{ .workspace = @enumFromInt(2) }, .tab_id = @enumFromInt(2) },
        .size = .{ .cols = 4, .rows = 2 },
    }));
    try std.testing.expectEqual(@as(usize, 1), model.tabs.count);
    try std.testing.expect(model.panes.find(@enumFromInt(1)) != null);
}
