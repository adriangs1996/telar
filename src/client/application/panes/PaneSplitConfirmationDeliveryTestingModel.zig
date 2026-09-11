const ModelType = @import("../../model/Model.zig");
const TabLocationType = @import("telar-core").TabLocation;
const PaneIdType = @import("telar-core").PaneId;
const RectType = @import("telar-core").Rect;
const std = @import("std");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const PaneSplitCommitType = @import("../../model/PaneSplitCommit.zig");
const CommitPaneSplitType = @import("../../model/CommitPaneSplit.zig");
const TestingModel = @This();

model: *ModelType,
first: TabLocationType,
second: TabLocationType,
first_pane: PaneIdType,
second_pane: PaneIdType,
created_pane: PaneIdType,
area: RectType,

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
    const second_pane: PaneIdType = @enumFromInt(2);
    const created_pane: PaneIdType = @enumFromInt(3);
    try model.workspace.bootstrap(.{ .pane_id = first_pane, .location = first, .size = .{ .cols = 40, .rows = 10 } });

    return .{
        .model = model,
        .first = first,
        .second = second,
        .first_pane = first_pane,
        .second_pane = second_pane,
        .created_pane = created_pane,
        .area = .{ .w = 40, .h = 10 },
    };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}

pub fn activeCommit(testing: *TestingModel) !PaneSplitCommitType {
    return testing.model.commitPaneSplit(testing.command());
}

pub fn inactiveCommit(testing: *TestingModel) !PaneSplitCommitType {
    try testing.addSecondTab();

    return testing.model.commitPaneSplit(testing.command());
}

pub fn staleCommit(testing: *TestingModel) !PaneSplitCommitType {
    try testing.addSecondTab();
    if (!testing.model.workspace.remove(testing.first.tab_id)) {
        return error.MissingTab;
    }

    return testing.model.commitPaneSplit(testing.command());
}

pub fn foreignWorkspaceCommit(testing: *TestingModel) !PaneSplitCommitType {
    const foreign: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(2) },
        .tab_id = testing.second.tab_id,
    };
    try testing.model.workspace.replaceWithRoot(.{
        .pane_id = testing.second_pane,
        .location = foreign,
        .size = .{ .cols = 40, .rows = 10 },
    });

    return testing.model.commitPaneSplit(testing.command());
}

fn addSecondTab(testing: *TestingModel) !void {
    _ = try testing.model.workspace.addCreated(.{
        .location = testing.second,
        .position = 1,
        .label = "second",
        .root_pane_id = testing.second_pane,
    }, .{ .cols = 40, .rows = 10 });
}

fn command(testing: *const TestingModel) CommitPaneSplitType {
    return .{
        .split = .{
            .target_pane = testing.first_pane,
            .location = testing.first,
            .axis = .horizontal,
            .area = testing.area,
        },
        .new_pane = testing.created_pane,
    };
}
