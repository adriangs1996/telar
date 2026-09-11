const ModelType = @import("../../model/Model.zig");
const PaneIdType = @import("telar-core").PaneId;
const std = @import("std");
const TabLocationType = @import("telar-core").TabLocation;
const TestingModel = @This();

model: *ModelType,
pane_id: PaneIdType,

pub fn init() !TestingModel {
    const model = try std.testing.allocator.create(ModelType);
    errdefer std.testing.allocator.destroy(model);
    model.* = ModelType.init(std.testing.allocator, true);
    errdefer model.deinit();

    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: PaneIdType = @enumFromInt(1);
    try model.workspace.bootstrap(.{ .pane_id = pane_id, .location = location, .size = .{ .cols = 10, .rows = 5 } });
    const pane = model.workspace.findPane(pane_id).?;
    pane.scroll = .{ .total_rows = 15, .offset = 10 };
    pane.cursor = .{ .visible = true, .x = 0, .y = 4 };

    return .{ .model = model, .pane_id = pane_id };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}
