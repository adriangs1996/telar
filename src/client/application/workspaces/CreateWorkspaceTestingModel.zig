const TestingModel = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("create_workspace.zig");
const std = @import("std");
model: *client_model.Model,
location: source_namespace.schema.TabLocation,

pub fn init() !TestingModel {
    const model = try std.testing.allocator.create(client_model.Model);
    errdefer std.testing.allocator.destroy(model);
    model.* = client_model.Model.init(std.testing.allocator, true);
    errdefer model.deinit();

    const location: source_namespace.schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.workspace.bootstrap(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 20, .rows = 5 } });

    return .{ .model = model, .location = location };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}

pub fn arrival(testing: *const TestingModel) client_model.WorkspaceArrival {
    _ = testing;

    return .{
        .pane_id = @enumFromInt(2),
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(2) },
            .tab_id = @enumFromInt(2),
        },
        .size = .{ .cols = 30, .rows = 8 },
    };
}
