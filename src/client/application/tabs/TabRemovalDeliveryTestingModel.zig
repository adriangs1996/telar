const ModelType = @import("../../model/Model.zig");
const TabLocationType = @import("telar-core").TabLocation;
const PaneIdType = @import("telar-core").PaneId;
const std = @import("std");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const types = @import("../../model/types.zig");
const TestingModel = @This();

model: *ModelType,
removed: TabLocationType,
successor: TabLocationType,
removed_root: PaneIdType,
removed_sibling: PaneIdType,
successor_root: PaneIdType,

pub fn init(with_successor: bool) !TestingModel {
    const model = try std.testing.allocator.create(ModelType);
    errdefer std.testing.allocator.destroy(model);
    model.* = ModelType.init(std.testing.allocator, true);
    errdefer model.deinit();

    const workspace: WorkspaceLocationType = .{ .workspace = @enumFromInt(1) };
    const removed: TabLocationType = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    const successor: TabLocationType = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    const removed_root: PaneIdType = @enumFromInt(1);
    const removed_sibling: PaneIdType = @enumFromInt(2);
    const successor_root: PaneIdType = @enumFromInt(3);
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

pub fn removeActive(testing: *TestingModel) !types.TabRemovalCommit {
    return testing.model.removeTab(.{
        .location = testing.removed,
        .workspace_removed = false,
    });
}

pub fn removeInactive(testing: *TestingModel) !types.TabRemovalCommit {
    return testing.model.removeTab(.{
        .location = testing.successor,
        .workspace_removed = false,
    });
}

pub fn removeWorkspace(testing: *TestingModel) !types.TabRemovalCommit {
    return testing.model.removeTab(.{
        .location = testing.removed,
        .workspace_removed = true,
    });
}
