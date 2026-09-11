const ModelType = @import("../../model/Model.zig");
const TabLocationType = @import("telar-core").TabLocation;
const PaneIdType = @import("telar-core").PaneId;
const std = @import("std");
const PaneAttachmentType = @import("../../model/PaneAttachment.zig");
const TestingModel = @This();

model: *ModelType,
location: TabLocationType,
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
    const discovered: PaneIdType = @enumFromInt(2);
    try model.workspace.bootstrap(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 20, .rows = 5 } });
    try model.workspace.active().?.model.addDiscovered(.{ .pane_id = discovered, .location = location, .area = .{ .w = 40, .h = 10 } });

    return .{ .model = model, .location = location, .discovered = discovered };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}

pub fn attachment(testing: *const TestingModel) PaneAttachmentType {
    return .{ .pane_id = testing.discovered, .location = testing.location };
}
