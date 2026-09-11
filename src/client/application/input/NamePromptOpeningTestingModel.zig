const TestingModel = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("name_prompt_opening.zig");
const std = @import("std");
model: *client_model.Model,
workspace: source_namespace.schema.WorkspaceLocation,
first: source_namespace.schema.TabLocation,
second: source_namespace.schema.TabLocation,
first_pane: source_namespace.schema.PaneId,

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
