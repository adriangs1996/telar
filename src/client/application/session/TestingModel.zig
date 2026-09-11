const ModelType = @import("../../model/Model.zig");
const TabLocationType = @import("telar-core").TabLocation;
const std = @import("std");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const TestingModel = @This();

model: *ModelType,
locations: [3]TabLocationType,

pub fn init(tab_count: usize) !TestingModel {
    std.debug.assert(tab_count <= 3);
    const model = try std.testing.allocator.create(ModelType);
    errdefer std.testing.allocator.destroy(model);
    model.* = ModelType.init(std.testing.allocator, true);
    errdefer model.deinit();
    const workspace: WorkspaceLocationType = .{ .workspace = @enumFromInt(1) };
    const locations = [3]TabLocationType{
        .{ .workspace = workspace, .tab_id = @enumFromInt(1) },
        .{ .workspace = workspace, .tab_id = @enumFromInt(2) },
        .{ .workspace = workspace, .tab_id = @enumFromInt(3) },
    };

    if (tab_count > 0) {
        try model.workspace.bootstrap(.{ .pane_id = @enumFromInt(1), .location = locations[0], .size = .{ .cols = 20, .rows = 5 } });
    }
    var index: usize = 1;
    while (index < tab_count) : (index += 1) {
        _ = try model.workspace.addCreated(.{
            .location = locations[index],
            .position = @intCast(index),
            .label = "tab",
            .root_pane_id = @enumFromInt(index + 1),
        }, .{ .cols = 20, .rows = 5 });
    }

    return .{ .model = model, .locations = locations };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}
