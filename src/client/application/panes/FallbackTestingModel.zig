const ModelType = @import("../../model/Model.zig");
const PaneIdType = @import("telar-core").PaneId;
const std = @import("std");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const TabLocationType = @import("telar-core").TabLocation;
const FallbackTestingModel = @This();

model: *ModelType,
first: PaneIdType,
second: PaneIdType,
third: PaneIdType,

pub fn init() !FallbackTestingModel {
    const model = try std.testing.allocator.create(ModelType);
    errdefer std.testing.allocator.destroy(model);
    model.* = ModelType.init(std.testing.allocator, true);
    errdefer model.deinit();

    const workspace: WorkspaceLocationType = .{ .workspace = @enumFromInt(1) };
    const first_location: TabLocationType = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    const second_location: TabLocationType = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    const first: PaneIdType = @enumFromInt(1);
    const second: PaneIdType = @enumFromInt(2);
    const third: PaneIdType = @enumFromInt(3);
    try model.workspace.bootstrap(.{ .pane_id = first, .location = first_location, .size = .{ .cols = 20, .rows = 5 } });
    try model.workspace.active().?.model.split(.{ .existing_pane = first, .new_pane = second, .location = first_location, .axis = .horizontal, .area = .{ .w = 20, .h = 5 } });
    _ = try model.workspace.addCreated(.{
        .location = second_location,
        .position = 1,
        .label = "logs",
        .root_pane_id = third,
    }, .{ .cols = 20, .rows = 5 });

    return .{
        .model = model,
        .first = first,
        .second = second,
        .third = third,
    };
}

pub fn deinit(testing: *FallbackTestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}
