const TestingModel = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("tab_snapshot.zig");
const std = @import("std");
model: *client_model.Model,
location: source_namespace.schema.TabLocation,
root_pane: source_namespace.schema.PaneId,
discovered_pane: source_namespace.schema.PaneId,
pane_ids: [2]source_namespace.schema.PaneId,

pub fn init() !TestingModel {
    const model = try std.testing.allocator.create(client_model.Model);
    errdefer std.testing.allocator.destroy(model);
    model.* = client_model.Model.init(std.testing.allocator, true);
    errdefer model.deinit();

    const location: source_namespace.schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const root_pane: source_namespace.schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(.{ .pane_id = root_pane, .location = location, .size = .{ .cols = 20, .rows = 5 } });

    const discovered_pane: source_namespace.schema.PaneId = @enumFromInt(2);

    return .{
        .model = model,
        .location = location,
        .root_pane = root_pane,
        .discovered_pane = discovered_pane,
        .pane_ids = .{ root_pane, discovered_pane },
    };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}

pub fn snapshot(testing: *const TestingModel) client_model.TabSnapshot {
    return .{
        .location = testing.location,
        .panes = &testing.pane_ids,
    };
}
