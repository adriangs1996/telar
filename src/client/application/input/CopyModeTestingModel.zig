const TestingModel = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("copy_mode.zig");
const std = @import("std");
model: *client_model.Model,
pane_id: source_namespace.schema.PaneId,

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
