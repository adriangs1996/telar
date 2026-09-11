const ModelType = @import("../../model/Model.zig");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const TabLocationType = @import("telar-core").TabLocation;
const PaneIdType = @import("telar-core").PaneId;
const WorkspaceTabInputType = @import("../../workspace/WorkspaceTabInput.zig");
const std = @import("std");
const WorkspaceSnapshotInput = @import("../../workspace/WorkspaceSnapshotInput.zig");
const WorkspaceReconciliationType = @import("../../model/WorkspaceReconciliation.zig");
const TestingModel = @This();

model: *ModelType,
workspace: WorkspaceLocationType,
first: TabLocationType,
second: TabLocationType,
first_pane: PaneIdType,
second_pane: PaneIdType,
tabs: [1]WorkspaceTabInputType,

pub fn init(two_tabs: bool) !TestingModel {
    const model = try std.testing.allocator.create(ModelType);
    errdefer std.testing.allocator.destroy(model);
    model.* = ModelType.init(std.testing.allocator, true);
    errdefer model.deinit();

    const workspace: WorkspaceLocationType = .{ .workspace = @enumFromInt(1) };
    const first: TabLocationType = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    const second: TabLocationType = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    const first_pane: PaneIdType = @enumFromInt(1);
    const second_pane: PaneIdType = @enumFromInt(2);
    try model.workspace.bootstrap(.{ .pane_id = first_pane, .location = first, .size = .{ .cols = 20, .rows = 5 } });
    if (two_tabs) {
        _ = try model.workspace.addCreated(.{
            .location = second,
            .position = 1,
            .label = "logs",
            .root_pane_id = second_pane,
        }, .{ .cols = 20, .rows = 5 });
    }

    return .{
        .model = model,
        .workspace = workspace,
        .first = first,
        .second = second,
        .first_pane = first_pane,
        .second_pane = second_pane,
        .tabs = .{.{
            .tab_id = first.tab_id,
            .pane_count = 1,
            .label = "main",
        }},
    };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}

fn snapshot(testing: *const TestingModel) WorkspaceSnapshotInput {
    return .{
        .workspace = testing.workspace,
        .name = "main",
        .tabs = &testing.tabs,
    };
}

pub fn reconcile(testing: *TestingModel) !WorkspaceReconciliationType {
    return testing.model.reconcileWorkspace(testing.snapshot());
}
