const ModelType = @import("../../model/Model.zig");
const TabLocationType = @import("telar-core").TabLocation;
const PaneIdType = @import("telar-core").PaneId;
const std = @import("std");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const TabReconciliationType = @import("../../model/TabReconciliation.zig");
const RectType = @import("telar-core").Rect;
const TestingModel = @This();

model: *ModelType,
target: TabLocationType,
root: PaneIdType,
discovered: PaneIdType,
other_pane: PaneIdType,
many: [2]PaneIdType,
root_only: [1]PaneIdType,

pub fn init(target_active: bool) !TestingModel {
    const model = try std.testing.allocator.create(ModelType);
    errdefer std.testing.allocator.destroy(model);
    model.* = ModelType.init(std.testing.allocator, true);
    errdefer model.deinit();

    const workspace: WorkspaceLocationType = .{ .workspace = @enumFromInt(1) };
    const target: TabLocationType = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    const other: TabLocationType = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    const root: PaneIdType = @enumFromInt(1);
    const discovered: PaneIdType = @enumFromInt(2);
    const other_pane: PaneIdType = @enumFromInt(3);
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

pub fn reconcileMany(testing: *TestingModel) !TabReconciliationType {
    return testing.reconcile(&testing.many);
}

pub fn reconcileRoot(testing: *TestingModel) !TabReconciliationType {
    return testing.reconcile(&testing.root_only);
}

pub fn reconcile(testing: *TestingModel, panes: []const PaneIdType) !TabReconciliationType {
    return testing.reconcileIn(panes, .{ .w = 40, .h = 10 });
}

pub fn reconcileIn(testing: *TestingModel, panes: []const PaneIdType, area: RectType) !TabReconciliationType {
    return testing.model.reconcileTab(.{
        .location = testing.target,
        .panes = panes,
    }, area);
}
