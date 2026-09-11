const ModelType = @import("../../model/Model.zig");
const PaneIdType = @import("telar-core").PaneId;
const std = @import("std");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const TabLocationType = @import("telar-core").TabLocation;
const TestingModel = @This();

model: *ModelType,
root: PaneIdType,
sibling: PaneIdType,
other_root: PaneIdType,

pub fn init() !TestingModel {
    const model = try std.testing.allocator.create(ModelType);
    errdefer std.testing.allocator.destroy(model);
    model.* = ModelType.init(std.testing.allocator, true);
    errdefer model.deinit();

    const workspace: WorkspaceLocationType = .{ .workspace = @enumFromInt(1) };
    const active: TabLocationType = .{ .workspace = workspace, .tab_id = @enumFromInt(1) };
    const other: TabLocationType = .{ .workspace = workspace, .tab_id = @enumFromInt(2) };
    const root: PaneIdType = @enumFromInt(1);
    const sibling: PaneIdType = @enumFromInt(2);
    const other_root: PaneIdType = @enumFromInt(3);
    try model.workspace.bootstrap(.{ .pane_id = root, .location = active, .size = .{ .cols = 40, .rows = 10 } });
    try model.workspace.active().?.model.split(.{ .existing_pane = root, .new_pane = sibling, .location = active, .axis = .horizontal, .area = .{ .w = 40, .h = 10 } });
    _ = try model.workspace.addCreated(.{
        .location = other,
        .position = 1,
        .label = "other",
        .root_pane_id = other_root,
    }, .{ .cols = 40, .rows = 10 });
    if (!model.workspace.select(active.tab_id)) {
        return error.ActiveTabNotRestored;
    }
    if (!model.workspace.active().?.model.focusPane(root)) {
        return error.ActiveFocusNotRestored;
    }

    const root_pane = model.workspace.findPane(root).?;
    root_pane.input_modes.bracketed_paste = true;
    root_pane.input_modes.focus_events = true;
    model.workspace.findPane(sibling).?.attached = false;
    _ = model.beginPanePaste().?;
    _ = model.syncReportedPaneFocus().?;

    return .{
        .model = model,
        .root = root,
        .sibling = sibling,
        .other_root = other_root,
    };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}
