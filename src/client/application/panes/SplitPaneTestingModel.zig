const TestingModel = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("split_pane.zig");
const std = @import("std");
model: *client_model.Model,
location: source_namespace.schema.TabLocation,
pane_id: source_namespace.schema.PaneId,
area: source_namespace.ui.Rect = .{ .w = 40, .h = 10 },

pub fn init() !TestingModel {
    const model = try std.testing.allocator.create(client_model.Model);
    errdefer std.testing.allocator.destroy(model);
    model.* = client_model.Model.init(std.testing.allocator, true);
    errdefer model.deinit();

    const location: source_namespace.schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: source_namespace.schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(.{ .pane_id = pane_id, .location = location, .size = .{ .cols = 40, .rows = 10 } });
    model.workspace.active().?.model.setCellSize(8, 16);

    return .{ .model = model, .location = location, .pane_id = pane_id };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}

pub fn split(testing: *const TestingModel) source_namespace.PaneSplit {
    return .{
        .target_pane = testing.pane_id,
        .location = testing.location,
        .axis = .horizontal,
        .area = testing.area,
    };
}
