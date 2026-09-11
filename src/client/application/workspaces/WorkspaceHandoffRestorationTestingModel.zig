const TestingModel = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("workspace_handoff_restoration.zig");
const std = @import("std");
model: *client_model.Model,
active: source_namespace.schema.TabLocation,
root: source_namespace.schema.PaneId,
sibling: source_namespace.schema.PaneId,
inactive_pane: source_namespace.schema.PaneId,

pub fn init() !TestingModel {
    const model = try std.testing.allocator.create(client_model.Model);
    errdefer std.testing.allocator.destroy(model);
    model.* = client_model.Model.init(std.testing.allocator, true);
    errdefer model.deinit();

    const workspace: source_namespace.schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const active: source_namespace.schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    const inactive: source_namespace.schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    const root: source_namespace.schema.PaneId = @enumFromInt(1);
    const sibling: source_namespace.schema.PaneId = @enumFromInt(2);
    const inactive_pane: source_namespace.schema.PaneId = @enumFromInt(3);
    try model.workspace.bootstrap(.{ .pane_id = root, .location = active, .size = .{ .cols = 40, .rows = 10 } });
    try model.workspace.active().?.model.split(.{ .existing_pane = root, .new_pane = sibling, .location = active, .axis = .horizontal, .area = .{ .w = 40, .h = 10 } });
    _ = try model.workspace.addCreated(.{
        .location = inactive,
        .position = 1,
        .label = "logs",
        .root_pane_id = inactive_pane,
    }, .{ .cols = 40, .rows = 10 });
    if (!model.workspace.select(active.tab_id)) {
        return error.ActiveTabNotRestored;
    }

    return .{
        .model = model,
        .active = active,
        .root = root,
        .sibling = sibling,
        .inactive_pane = inactive_pane,
    };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}
