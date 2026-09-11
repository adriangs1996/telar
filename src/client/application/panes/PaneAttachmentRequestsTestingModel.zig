const ModelType = @import("../../model/Model.zig");
const TabLocationType = @import("telar-core").TabLocation;
const PaneIdType = @import("telar-core").PaneId;
const std = @import("std");
const RectType = @import("telar-core").Rect;
const TestingModel = @This();

model: *ModelType,
location: TabLocationType,
root: PaneIdType,
discovered: PaneIdType,

pub fn init() !TestingModel {
    const model = try std.testing.allocator.create(ModelType);
    errdefer std.testing.allocator.destroy(model);
    model.* = ModelType.init(std.testing.allocator, true);
    errdefer model.deinit();
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const root: PaneIdType = @enumFromInt(1);
    try model.workspace.bootstrap(.{ .pane_id = root, .location = location, .size = .{ .cols = 20, .rows = 5 } });

    return .{ .model = model, .location = location, .root = root, .discovered = @enumFromInt(2) };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}

pub fn reconcile(testing: *TestingModel, area: RectType) !void {
    _ = try testing.model.reconcileTab(.{
        .location = testing.location,
        .panes = &.{ testing.root, testing.discovered },
    }, area);
}
