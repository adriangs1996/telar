const FallbackTestingModel = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("pane_graphics.zig");
const std = @import("std");
model: *client_model.Model,
first: source_namespace.schema.PaneId,
second: source_namespace.schema.PaneId,
third: source_namespace.schema.PaneId,

pub fn init() !FallbackTestingModel {
    const model = try std.testing.allocator.create(client_model.Model);
    errdefer std.testing.allocator.destroy(model);
    model.* = client_model.Model.init(std.testing.allocator, true);
    errdefer model.deinit();

    const workspace: source_namespace.schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first_location: source_namespace.schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    const second_location: source_namespace.schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    const first: source_namespace.schema.PaneId = @enumFromInt(1);
    const second: source_namespace.schema.PaneId = @enumFromInt(2);
    const third: source_namespace.schema.PaneId = @enumFromInt(3);
    try model.workspace.bootstrap(.{ .pane_id = first, .location = first_location, .size = .{ .cols = 20, .rows = 5 } });
    try model.workspace.active().?.model.split(.{ .existing_pane = first, .new_pane = second, .location = first_location, .axis = .horizontal, .area = .{ .w = 20, .h = 5 } });
    _ = try model.workspace.addCreated(.{
        .location = second_location,
        .position = 1,
        .label = "logs",
        .root_pane_id = third,
    }, .{ .cols = 20, .rows = 5 });

    return .{
        .model = model,
        .first = first,
        .second = second,
        .third = third,
    };
}

pub fn deinit(testing: *FallbackTestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}
