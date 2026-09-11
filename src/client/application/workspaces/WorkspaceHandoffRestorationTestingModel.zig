const ModelType = @import("../../model/Model.zig");
const TabLocationType = @import("telar-core").TabLocation;
const PaneIdType = @import("telar-core").PaneId;
const std = @import("std");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const TestingModel = @This();

model: *ModelType,
active: TabLocationType,
root: PaneIdType,
sibling: PaneIdType,
inactive_pane: PaneIdType,

pub fn init() !TestingModel {
    const model = try std.testing.allocator.create(ModelType);
    errdefer std.testing.allocator.destroy(model);
    model.* = ModelType.init(std.testing.allocator, true);
    errdefer model.deinit();

    const workspace: WorkspaceLocationType = .{ .workspace = @enumFromInt(1) };
    const active: TabLocationType = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    const inactive: TabLocationType = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    const root: PaneIdType = @enumFromInt(1);
    const sibling: PaneIdType = @enumFromInt(2);
    const inactive_pane: PaneIdType = @enumFromInt(3);
    try model.workspace.bootstrap(.{ .pane_id = root, .location = active, .size = .{ .cols = 40, .rows = 10 } });
    try model.workspace.active().?.model.split(.{ .existing_pane = root, .new_pane = sibling, .location = active, .axis = .horizontal, .area = .{ .w = 40, .h = 10 } });
    _ = try model.workspace.addCreated(.{
        .location = inactive,
        .position = 1,
        .label = "logs",
        .root_pane_id = inactive_pane,
    }, .{ .cols = 40, .rows = 10 });
    if (!model.workspace.select(active.tab_id)) {
        return error.ActiveTabNotRestored;
    }

    return .{
        .model = model,
        .active = active,
        .root = root,
        .sibling = sibling,
        .inactive_pane = inactive_pane,
    };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}
