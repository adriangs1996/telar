const TestingModel = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("resize_pane.zig");
const std = @import("std");
model: *client_model.Model,
location: source_namespace.schema.TabLocation,
first: source_namespace.schema.PaneId,
area: source_namespace.ui.Rect = .{ .w = 101, .h = 41 },

pub fn init() !TestingModel {
    const model = try std.testing.allocator.create(client_model.Model);
    errdefer std.testing.allocator.destroy(model);
    model.* = client_model.Model.init(std.testing.allocator, true);
    errdefer model.deinit();

    const location: source_namespace.schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const first: source_namespace.schema.PaneId = @enumFromInt(1);
    const second: source_namespace.schema.PaneId = @enumFromInt(2);
    try model.workspace.bootstrap(.{ .pane_id = first, .location = location, .size = .{ .cols = 101, .rows = 41 } });
    try model.workspace.active().?.model.split(.{ .existing_pane = first, .new_pane = second, .location = location, .axis = .horizontal, .area = .{ .w = 101, .h = 41 } });
    try std.testing.expect(model.workspace.active().?.model.focusPane(first));

    return .{
        .model = model,
        .location = location,
        .first = first,
    };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}
