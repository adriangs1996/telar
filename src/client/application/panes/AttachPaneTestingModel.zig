const TestingModel = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("attach_pane.zig");
const std = @import("std");
model: *client_model.Model,
location: source_namespace.schema.TabLocation,
discovered: source_namespace.schema.PaneId,

pub fn init() !TestingModel {
    const model = try std.testing.allocator.create(client_model.Model);
    errdefer std.testing.allocator.destroy(model);
    model.* = client_model.Model.init(std.testing.allocator, true);
    errdefer model.deinit();

    const location: source_namespace.schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const discovered: source_namespace.schema.PaneId = @enumFromInt(2);
    try model.workspace.bootstrap(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 20, .rows = 5 } });
    try model.workspace.active().?.model.addDiscovered(.{ .pane_id = discovered, .location = location, .area = .{ .w = 40, .h = 10 } });

    return .{ .model = model, .location = location, .discovered = discovered };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}

pub fn attachment(testing: *const TestingModel) source_namespace.PaneAttachment {
    return .{ .pane_id = testing.discovered, .location = testing.location };
}
