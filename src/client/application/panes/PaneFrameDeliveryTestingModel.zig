const TestingModel = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("pane_frame_delivery.zig");
const std = @import("std");
model: *client_model.Model,
pane_id: source_namespace.schema.PaneId,

pub fn init() !TestingModel {
    const model = try std.testing.allocator.create(client_model.Model);
    errdefer std.testing.allocator.destroy(model);
    model.* = client_model.Model.init(std.testing.allocator, true);
    errdefer model.deinit();

    const location: source_namespace.schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: source_namespace.schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(.{ .pane_id = pane_id, .location = location, .size = .{ .cols = 2, .rows = 2 } });

    return .{
        .model = model,
        .pane_id = pane_id,
    };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}

pub fn applyFrame(testing: *TestingModel, scroll: source_namespace.schema.frame.Scroll) !client_model.PaneFrameCommit {
    const cells = [_]source_namespace.ui.Cell{ .{}, .{}, .{}, .{} };
    var encoded: [512]u8 = undefined;
    const bytes = try source_namespace.schema.encodePaneFrame(&encoded, .{
        .pane_id = testing.pane_id,
        .frame_id = 7,
        .base_frame_id = 0,
        .cols = 2,
        .rows = 2,
        .scroll = scroll,
        .spans = &.{.{ .start = 0, .cells = &cells }},
    });
    const outcome = try testing.model.applyPaneFrame((try source_namespace.schema.decodeServer(bytes)).pane_frame);

    return outcome.applied;
}
