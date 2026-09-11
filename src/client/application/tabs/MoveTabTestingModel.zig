const TestingModel = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("move_tab.zig");
const std = @import("std");
model: *client_model.Model,
first: source_namespace.schema.TabLocation,
second: source_namespace.schema.TabLocation,

pub fn init() !TestingModel {
    const model = try std.testing.allocator.create(client_model.Model);
    errdefer std.testing.allocator.destroy(model);
    model.* = client_model.Model.init(std.testing.allocator, true);
    errdefer model.deinit();

    const workspace: source_namespace.schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: source_namespace.schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    const second: source_namespace.schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    try model.workspace.bootstrap(.{ .pane_id = @enumFromInt(1), .location = first, .size = .{ .cols = 20, .rows = 5 } });
    _ = try model.workspace.addCreated(.{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    _ = model.workspace.select(second.tab_id);

    return .{ .model = model, .first = first, .second = second };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}
