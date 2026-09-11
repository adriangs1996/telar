const TestingModel = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("client_detachment.zig");
const std = @import("std");
model: *client_model.Model,
locations: [3]source_namespace.schema.TabLocation,

pub fn init(tab_count: usize) !TestingModel {
    std.debug.assert(tab_count <= 3);
    const model = try std.testing.allocator.create(client_model.Model);
    errdefer std.testing.allocator.destroy(model);
    model.* = client_model.Model.init(std.testing.allocator, true);
    errdefer model.deinit();
    const workspace: source_namespace.schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const locations = [3]source_namespace.schema.TabLocation{
        .{ .workspace = workspace, .tab_id = @enumFromInt(1) },
        .{ .workspace = workspace, .tab_id = @enumFromInt(2) },
        .{ .workspace = workspace, .tab_id = @enumFromInt(3) },
    };

    if (tab_count > 0) {
        try model.workspace.bootstrap(.{ .pane_id = @enumFromInt(1), .location = locations[0], .size = .{ .cols = 20, .rows = 5 } });
    }
    var index: usize = 1;
    while (index < tab_count) : (index += 1) {
        _ = try model.workspace.addCreated(.{
            .location = locations[index],
            .position = @intCast(index),
            .label = "tab",
            .root_pane_id = @enumFromInt(index + 1),
        }, .{ .cols = 20, .rows = 5 });
    }

    return .{ .model = model, .locations = locations };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}
