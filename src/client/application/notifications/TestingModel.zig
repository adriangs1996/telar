const ModelType = @import("../../model/Model.zig");
const std = @import("std");
const TestingModel = @This();

model: *ModelType,

pub fn init(active: bool) !TestingModel {
    const model = try std.testing.allocator.create(ModelType);
    errdefer std.testing.allocator.destroy(model);
    model.* = ModelType.init(std.testing.allocator, true);
    errdefer model.deinit();
    if (active) {
        try model.workspace.bootstrap(.{ .pane_id = @enumFromInt(1), .location = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        }, .size = .{ .cols = 20, .rows = 5 } });
    }

    return .{ .model = model };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}
