const TestingModel = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("rename_workspace.zig");
const std = @import("std");
model: *client_model.Model,
workspace: source_namespace.schema.WorkspaceLocation,

pub fn init() !TestingModel {
    const model = try std.testing.allocator.create(client_model.Model);
    errdefer std.testing.allocator.destroy(model);
    model.* = client_model.Model.init(std.testing.allocator, true);
    errdefer model.deinit();

    const workspace: source_namespace.schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    try model.workspace.bootstrap(.{ .pane_id = @enumFromInt(1), .location = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    }, .size = .{ .cols = 20, .rows = 5 } });

    return .{ .model = model, .workspace = workspace };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}
