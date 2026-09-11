const TestingModel = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("tab_snapshot_delivery.zig");
const std = @import("std");
model: *client_model.Model,
target: source_namespace.schema.TabLocation,
root: source_namespace.schema.PaneId,
discovered: source_namespace.schema.PaneId,
other_pane: source_namespace.schema.PaneId,
many: [2]source_namespace.schema.PaneId,
root_only: [1]source_namespace.schema.PaneId,

pub fn init(target_active: bool) !TestingModel {
    const model = try std.testing.allocator.create(client_model.Model);
    errdefer std.testing.allocator.destroy(model);
    model.* = client_model.Model.init(std.testing.allocator, true);
    errdefer model.deinit();

    const workspace: source_namespace.schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const target: source_namespace.schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    const other: source_namespace.schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    const root: source_namespace.schema.PaneId = @enumFromInt(1);
    const discovered: source_namespace.schema.PaneId = @enumFromInt(2);
    const other_pane: source_namespace.schema.PaneId = @enumFromInt(3);
    try model.workspace.bootstrap(.{ .pane_id = root, .location = target, .size = .{ .cols = 20, .rows = 5 } });
    if (!target_active) {
        _ = try model.workspace.addCreated(.{
            .location = other,
            .position = 1,
            .label = "other",
            .root_pane_id = other_pane,
        }, .{ .cols = 20, .rows = 5 });
    }

    return .{
        .model = model,
        .target = target,
        .root = root,
        .discovered = discovered,
        .other_pane = other_pane,
        .many = .{ root, discovered },
        .root_only = .{root},
    };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}

pub fn reconcileMany(testing: *TestingModel) !client_model.TabReconciliation {
    return testing.reconcile(&testing.many);
}

pub fn reconcileRoot(testing: *TestingModel) !client_model.TabReconciliation {
    return testing.reconcile(&testing.root_only);
}

pub fn reconcile(testing: *TestingModel, panes: []const source_namespace.schema.PaneId) !client_model.TabReconciliation {
    return testing.reconcileIn(panes, .{ .w = 40, .h = 10 });
}

pub fn reconcileIn(testing: *TestingModel, panes: []const source_namespace.schema.PaneId, area: source_namespace.ui.Rect) !client_model.TabReconciliation {
    return testing.model.reconcileTab(.{
        .location = testing.target,
        .panes = panes,
    }, area);
}
