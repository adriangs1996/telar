const ModelType = @import("../../model/Model.zig");
const TabLocationType = @import("telar-core").TabLocation;
const std = @import("std");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const TestingModel = @This();

model: *ModelType,
first: TabLocationType,
second: TabLocationType,

pub fn init(with_second: bool) !TestingModel {
    const model = try std.testing.allocator.create(ModelType);
    errdefer std.testing.allocator.destroy(model);
    model.* = ModelType.init(std.testing.allocator, true);
    errdefer model.deinit();

    const workspace: WorkspaceLocationType = .{ .workspace = @enumFromInt(1) };
    const first: TabLocationType = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    const second: TabLocationType = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    try model.workspace.bootstrap(.{ .pane_id = @enumFromInt(1), .location = first, .size = .{ .cols = 20, .rows = 5 } });
    if (with_second) {
        _ = try model.workspace.addCreated(.{
            .location = second,
            .position = 1,
            .label = "logs",
            .root_pane_id = @enumFromInt(2),
        }, .{ .cols = 20, .rows = 5 });
        try std.testing.expect(model.workspace.select(first.tab_id));
    }

    return .{ .model = model, .first = first, .second = second };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}
