const TestingModel = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("pane_closure_delivery.zig");
const core = @import("telar-core");
const std = @import("std");
model: *client_model.Model,
active: source_namespace.schema.TabLocation,
inactive: source_namespace.schema.TabLocation,
first: source_namespace.schema.PaneId,
second: source_namespace.schema.PaneId,
inactive_pane: source_namespace.schema.PaneId,
area: core.ui.Rect,

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
    const first: source_namespace.schema.PaneId = @enumFromInt(1);
    const second: source_namespace.schema.PaneId = @enumFromInt(2);
    const inactive_pane: source_namespace.schema.PaneId = @enumFromInt(3);
    const area: core.ui.Rect = .{ .w = 40, .h = 10 };
    try model.workspace.bootstrap(.{ .pane_id = first, .location = active, .size = .{ .cols = 40, .rows = 10 } });
    try model.workspace.active().?.model.split(.{ .existing_pane = first, .new_pane = second, .location = active, .axis = .horizontal, .area = area });
    _ = try model.workspace.addCreated(.{
        .location = inactive,
        .position = 1,
        .label = "inactive",
        .root_pane_id = inactive_pane,
    }, .{ .cols = 40, .rows = 10 });
    if (!model.workspace.select(active.tab_id)) {
        return error.ActiveTabNotRestored;
    }

    return .{
        .model = model,
        .active = active,
        .inactive = inactive,
        .first = first,
        .second = second,
        .inactive_pane = inactive_pane,
        .area = area,
    };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}
