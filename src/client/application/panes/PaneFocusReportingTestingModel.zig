const ModelType = @import("../../model/Model.zig");
const PaneIdType = @import("telar-core").PaneId;
const std = @import("std");
const TabLocationType = @import("telar-core").TabLocation;
const TestingModel = @This();

model: *ModelType,
first: PaneIdType,
second: PaneIdType,

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
    try model.workspace.bootstrap(.{ .pane_id = first, .location = location, .size = .{ .cols = 80, .rows = 24 } });
    try model.workspace.active().?.model.split(.{ .existing_pane = first, .new_pane = second, .location = location, .axis = .horizontal, .area = .{ .w = 80, .h = 24 } });
    try std.testing.expect(model.workspace.active().?.model.focusPane(first));

    return .{ .model = model, .first = first, .second = second };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}
