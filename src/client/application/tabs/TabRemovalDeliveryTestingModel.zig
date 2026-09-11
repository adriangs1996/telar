const TestingModel = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("tab_removal_delivery.zig");
const std = @import("std");
model: *client_model.Model,
removed: source_namespace.schema.TabLocation,
successor: source_namespace.schema.TabLocation,
removed_root: source_namespace.schema.PaneId,
removed_sibling: source_namespace.schema.PaneId,
successor_root: source_namespace.schema.PaneId,

pub fn init(with_successor: bool) !TestingModel {
    const model = try std.testing.allocator.create(client_model.Model);
    errdefer std.testing.allocator.destroy(model);
    model.* = client_model.Model.init(std.testing.allocator, true);
    errdefer model.deinit();

    const workspace: source_namespace.schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const removed: source_namespace.schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    const successor: source_namespace.schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    const removed_root: source_namespace.schema.PaneId = @enumFromInt(1);
    const removed_sibling: source_namespace.schema.PaneId = @enumFromInt(2);
    const successor_root: source_namespace.schema.PaneId = @enumFromInt(3);
    try model.workspace.bootstrap(.{ .pane_id = removed_root, .location = removed, .size = .{ .cols = 40, .rows = 10 } });
    try model.workspace.active().?.model.split(.{ .existing_pane = removed_root, .new_pane = removed_sibling, .location = removed, .axis = .horizontal, .area = .{ .w = 40, .h = 10 } });
    if (!model.workspace.active().?.model.focusPane(removed_root)) {
        return error.RemovedFocusNotRestored;
    }

    const root = model.workspace.findPane(removed_root).?;
    root.input_modes.bracketed_paste = true;
    root.input_modes.focus_events = true;
    _ = model.beginPanePaste().?;
    _ = model.syncReportedPaneFocus().?;

    if (with_successor) {
        const tab = try model.workspace.addCreated(.{
            .location = successor,
            .position = 1,
            .label = "successor",
            .root_pane_id = successor_root,
        }, .{ .cols = 40, .rows = 10 });
        tab.model.find(successor_root).?.attached = false;
        if (!model.workspace.select(removed.tab_id)) {
            return error.RemovedTabNotRestored;
        }
    }

    return .{
        .model = model,
        .removed = removed,
        .successor = successor,
        .removed_root = removed_root,
        .removed_sibling = removed_sibling,
        .successor_root = successor_root,
    };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}

pub fn removeActive(testing: *TestingModel) !client_model.TabRemovalCommit {
    return testing.model.removeTab(.{
        .location = testing.removed,
        .workspace_removed = false,
    });
}

pub fn removeInactive(testing: *TestingModel) !client_model.TabRemovalCommit {
    return testing.model.removeTab(.{
        .location = testing.successor,
        .workspace_removed = false,
    });
}

pub fn removeWorkspace(testing: *TestingModel) !client_model.TabRemovalCommit {
    return testing.model.removeTab(.{
        .location = testing.removed,
        .workspace_removed = true,
    });
}
