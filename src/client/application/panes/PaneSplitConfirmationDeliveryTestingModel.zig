const TestingModel = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("pane_split_confirmation_delivery.zig");
const core = @import("telar-core");
const std = @import("std");
model: *client_model.Model,
first: source_namespace.schema.TabLocation,
second: source_namespace.schema.TabLocation,
first_pane: source_namespace.schema.PaneId,
second_pane: source_namespace.schema.PaneId,
created_pane: source_namespace.schema.PaneId,
area: core.ui.Rect,

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
    const first_pane: source_namespace.schema.PaneId = @enumFromInt(1);
    const second_pane: source_namespace.schema.PaneId = @enumFromInt(2);
    const created_pane: source_namespace.schema.PaneId = @enumFromInt(3);
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

pub fn activeCommit(testing: *TestingModel) !client_model.PaneSplitCommit {
    return testing.model.commitPaneSplit(testing.command());
}

pub fn inactiveCommit(testing: *TestingModel) !client_model.PaneSplitCommit {
    try testing.addSecondTab();

    return testing.model.commitPaneSplit(testing.command());
}

pub fn staleCommit(testing: *TestingModel) !client_model.PaneSplitCommit {
    try testing.addSecondTab();
    if (!testing.model.workspace.remove(testing.first.tab_id)) {
        return error.MissingTab;
    }

    return testing.model.commitPaneSplit(testing.command());
}

pub fn foreignWorkspaceCommit(testing: *TestingModel) !client_model.PaneSplitCommit {
    const foreign: source_namespace.schema.TabLocation = .{
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

fn command(testing: *const TestingModel) client_model.CommitPaneSplit {
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
