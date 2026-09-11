const ModelType = @import("../../model/Model.zig");
const TabLocationType = @import("telar-core").TabLocation;
const PaneIdType = @import("telar-core").PaneId;
const std = @import("std");
const PaneSnapshot = @import("../../workspace/PaneSnapshot.zig");
const TestingModel = @This();

model: *ModelType,
location: TabLocationType,
root_pane: PaneIdType,
discovered_pane: PaneIdType,
pane_ids: [2]PaneIdType,

pub fn init() !TestingModel {
    const model = try std.testing.allocator.create(ModelType);
    errdefer std.testing.allocator.destroy(model);
    model.* = ModelType.init(std.testing.allocator, true);
    errdefer model.deinit();

    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const root_pane: PaneIdType = @enumFromInt(1);
    try model.workspace.bootstrap(.{ .pane_id = root_pane, .location = location, .size = .{ .cols = 20, .rows = 5 } });

    const discovered_pane: PaneIdType = @enumFromInt(2);

    return .{
        .model = model,
        .location = location,
        .root_pane = root_pane,
        .discovered_pane = discovered_pane,
        .pane_ids = .{ root_pane, discovered_pane },
    };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}

pub fn snapshot(testing: *const TestingModel) PaneSnapshot {
    return .{
        .location = testing.location,
        .panes = &testing.pane_ids,
    };
}
