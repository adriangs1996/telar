const ModelType = @import("../../model/Model.zig");
const TabLocationType = @import("telar-core").TabLocation;
const PaneIdType = @import("telar-core").PaneId;
const RectType = @import("telar-core").Rect;
const std = @import("std");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const TestingModel = @This();

model: *ModelType,
active: TabLocationType,
inactive: TabLocationType,
first: PaneIdType,
second: PaneIdType,
inactive_pane: PaneIdType,
area: RectType,

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
    const first: PaneIdType = @enumFromInt(1);
    const second: PaneIdType = @enumFromInt(2);
    const inactive_pane: PaneIdType = @enumFromInt(3);
    const area: RectType = .{ .w = 40, .h = 10 };
    try model.workspace.bootstrap(.{ .pane_id = first, .location = active, .size = .{ .cols = 40, .rows = 10 } });
    try model.workspace.active().?.model.split(.{ .existing_pane = first, .new_pane = second, .location = active, .axis = .horizontal, .area = area });
    _ = try model.workspace.addCreated(.{
        .location = inactive,
        .position = 1,
        .label = "inactive",
        .root_pane_id = inactive_pane,
    }, .{ .cols = 40, .rows = 10 });
    if (!model.workspace.select(active.tab_id)) {
        return error.ActiveTabNotRestored;
    }

    return .{
        .model = model,
        .active = active,
        .inactive = inactive,
        .first = first,
        .second = second,
        .inactive_pane = inactive_pane,
        .area = area,
    };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}
