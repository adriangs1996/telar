const TestingModel = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("pane_attachment_requests.zig");
const std = @import("std");
model: *client_model.Model,
location: source_namespace.schema.TabLocation,
root: source_namespace.schema.PaneId,
discovered: source_namespace.schema.PaneId,

pub fn init() !TestingModel {
    const model = try std.testing.allocator.create(client_model.Model);
    errdefer std.testing.allocator.destroy(model);
    model.* = client_model.Model.init(std.testing.allocator, true);
    errdefer model.deinit();
    const location: source_namespace.schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const root: source_namespace.schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(.{ .pane_id = root, .location = location, .size = .{ .cols = 20, .rows = 5 } });

    return .{ .model = model, .location = location, .root = root, .discovered = @enumFromInt(2) };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}

pub fn reconcile(testing: *TestingModel, area: source_namespace.ui.Rect) !void {
    _ = try testing.model.reconcileTab(.{
        .location = testing.location,
        .panes = &.{ testing.root, testing.discovered },
    }, area);
}
