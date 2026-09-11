const ModelType = @import("../../model/Model.zig");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const std = @import("std");
const TestingModel = @This();

model: *ModelType,
workspace: WorkspaceLocationType,

pub fn init() !TestingModel {
    const model = try std.testing.allocator.create(ModelType);
    errdefer std.testing.allocator.destroy(model);
    model.* = ModelType.init(std.testing.allocator, true);
    errdefer model.deinit();

    const workspace: WorkspaceLocationType = .{ .workspace = @enumFromInt(1) };
    try model.workspace.bootstrap(.{ .pane_id = @enumFromInt(1), .location = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    }, .size = .{ .cols = 20, .rows = 5 } });

    return .{ .model = model, .workspace = workspace };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}
