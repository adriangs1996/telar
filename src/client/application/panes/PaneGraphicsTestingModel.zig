const ModelType = @import("../../model/Model.zig");
const PaneIdType = @import("telar-core").PaneId;
const std = @import("std");
const pane_graphics = @import("pane_graphics.zig");
const TestingModel = @This();

model: *ModelType,
pane_id: PaneIdType,

pub fn init() !TestingModel {
    const model = try std.testing.allocator.create(ModelType);
    errdefer std.testing.allocator.destroy(model);
    model.* = ModelType.init(std.testing.allocator, true);
    errdefer model.deinit();
    const pane_id: PaneIdType = @enumFromInt(1);
    try model.workspace.bootstrap(.{ .pane_id = pane_id, .location = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    }, .size = .{ .cols = 2, .rows = 2 } });

    return .{ .model = model, .pane_id = pane_id };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}

pub fn command(testing: *const TestingModel) pane_graphics.Command {
    return .{ .snapshot = .{
        .pane_id = testing.pane_id,
        .revision = 1,
        .phase = .begin,
    } };
}
