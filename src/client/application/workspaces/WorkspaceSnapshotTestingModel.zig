const TestingModel = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("workspace_snapshot.zig");
const std = @import("std");
model: *client_model.Model,
workspace: source_namespace.schema.WorkspaceLocation,
first: source_namespace.schema.TabLocation,
second: source_namespace.schema.TabLocation,
tabs: [1]client_model.WorkspaceTabInput,

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
    try model.workspace.bootstrap(.{ .pane_id = @enumFromInt(1), .location = first, .size = .{ .cols = 20, .rows = 5 } });
    _ = try model.workspace.addCreated(.{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });

    return .{
        .model = model,
        .workspace = workspace,
        .first = first,
        .second = second,
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

pub fn snapshot(testing: *const TestingModel) client_model.WorkspaceSnapshot {
    return .{
        .workspace = testing.workspace,
        .name = "renamed",
        .tabs = &testing.tabs,
    };
}
