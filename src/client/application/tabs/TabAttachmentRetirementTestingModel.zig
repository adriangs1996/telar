const ModelType = @import("../../model/Model.zig");
const TabLocationType = @import("telar-core").TabLocation;
const PaneIdType = @import("telar-core").PaneId;
const std = @import("std");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const TestingModel = @This();

model: *ModelType,
target: TabLocationType,
active: TabLocationType,
root: PaneIdType,
sibling: PaneIdType,
active_pane: PaneIdType,

pub fn init() !TestingModel {
    const model = try std.testing.allocator.create(ModelType);
    errdefer std.testing.allocator.destroy(model);
    model.* = ModelType.init(std.testing.allocator, true);
    errdefer model.deinit();

    const workspace: WorkspaceLocationType = .{ .workspace = @enumFromInt(1) };
    const target: TabLocationType = .{ .workspace = workspace, .tab_id = @enumFromInt(1) };
    const active: TabLocationType = .{ .workspace = workspace, .tab_id = @enumFromInt(2) };
    const root: PaneIdType = @enumFromInt(1);
    const sibling: PaneIdType = @enumFromInt(2);
    const active_pane: PaneIdType = @enumFromInt(3);
    try model.workspace.bootstrap(.{ .pane_id = root, .location = target, .size = .{ .cols = 20, .rows = 5 } });
    try model.workspace.active().?.model.split(.{ .existing_pane = root, .new_pane = sibling, .location = target, .axis = .horizontal, .area = .{ .w = 40, .h = 10 } });
    try std.testing.expect(model.workspace.active().?.model.focusPane(root));
    const root_pane = model.workspace.findPane(root).?;
    const sibling_pane = model.workspace.findPane(sibling).?;
    root_pane.input_modes.bracketed_paste = true;
    root_pane.input_modes.focus_events = true;
    root_pane.pending_frame_id = 7;
    sibling_pane.attached = false;
    sibling_pane.pending_frame_id = 9;
    _ = model.beginPanePaste().?;
    _ = model.syncReportedPaneFocus().?;
    _ = try model.workspace.addCreated(.{
        .location = active,
        .position = 1,
        .label = "logs",
        .root_pane_id = active_pane,
    }, .{ .cols = 20, .rows = 5 });

    return .{
        .model = model,
        .target = target,
        .active = active,
        .root = root,
        .sibling = sibling,
        .active_pane = active_pane,
    };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}
