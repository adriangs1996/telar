const ModelType = @import("../../model/Model.zig");
const PaneIdType = @import("telar-core").PaneId;
const std = @import("std");
const PaneViewportChangeType = @import("../../model/PaneViewportChange.zig");
const TestingModel = @This();

model: *ModelType,
pane_id: PaneIdType,

pub fn init() !TestingModel {
    const model = try std.testing.allocator.create(ModelType);
    errdefer std.testing.allocator.destroy(model);
    model.* = ModelType.init(std.testing.allocator, true);
    errdefer model.deinit();
    const pane_id: PaneIdType = @enumFromInt(1);
    try model.workspace.bootstrap(.{ .pane_id = pane_id, .location = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    }, .size = .{ .cols = 10, .rows = 5 } });
    model.workspace.findPane(pane_id).?.scroll = .{ .total_rows = 20, .offset = 10 };

    return .{ .model = model, .pane_id = pane_id };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}

pub fn commitBottom(testing: *TestingModel) PaneViewportChangeType {
    return testing.model.setPaneViewport(.{
        .pane_id = testing.pane_id,
        .target = .bottom,
    }).?;
}
