const ModelType = @import("../../model/Model.zig");
const TabLocationType = @import("telar-core").TabLocation;
const PaneIdType = @import("telar-core").PaneId;
const RectType = @import("telar-core").Rect;
const std = @import("std");
const TestingModel = @This();

model: *ModelType,
location: TabLocationType,
first: PaneIdType,
area: RectType = .{ .w = 101, .h = 41 },

pub fn init() !TestingModel {
    const model = try std.testing.allocator.create(ModelType);
    errdefer std.testing.allocator.destroy(model);
    model.* = ModelType.init(std.testing.allocator, true);
    errdefer model.deinit();

    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const first: PaneIdType = @enumFromInt(1);
    const second: PaneIdType = @enumFromInt(2);
    try model.workspace.bootstrap(.{ .pane_id = first, .location = location, .size = .{ .cols = 101, .rows = 41 } });
    try model.workspace.active().?.model.split(.{ .existing_pane = first, .new_pane = second, .location = location, .axis = .horizontal, .area = .{ .w = 101, .h = 41 } });
    try std.testing.expect(model.workspace.active().?.model.focusPane(first));

    return .{
        .model = model,
        .location = location,
        .first = first,
    };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}
