const ModelType = @import("../../model/Model.zig");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const TabLocationType = @import("telar-core").TabLocation;
const PaneIdType = @import("telar-core").PaneId;
const std = @import("std");
const TestingModel = @This();

model: *ModelType,
workspace: WorkspaceLocationType,
first: TabLocationType,
second: TabLocationType,
first_pane: PaneIdType,

pub fn init() !TestingModel {
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
    try model.workspace.bootstrap(.{ .pane_id = first_pane, .location = first, .size = .{ .cols = 40, .rows = 10 } });
    _ = try model.workspace.addCreated(.{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 40, .rows = 10 });
    if (!model.workspace.select(first.tab_id)) {
        return error.ActiveTabNotRestored;
    }

    _ = try model.reconcileWorkspace(.{
        .workspace = workspace,
        .name = "project",
        .tabs = &.{
            .{ .tab_id = first.tab_id, .pane_count = 1, .label = "main" },
            .{ .tab_id = second.tab_id, .pane_count = 1, .label = "logs" },
        },
    });

    return .{
        .model = model,
        .workspace = workspace,
        .first = first,
        .second = second,
        .first_pane = first_pane,
    };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}
