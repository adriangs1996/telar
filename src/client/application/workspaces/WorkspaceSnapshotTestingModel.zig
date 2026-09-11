const ModelType = @import("../../model/Model.zig");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const TabLocationType = @import("telar-core").TabLocation;
const WorkspaceTabInputType = @import("../../workspace/WorkspaceTabInput.zig");
const std = @import("std");
const WorkspaceSnapshotInput = @import("../../workspace/WorkspaceSnapshotInput.zig");
const TestingModel = @This();

model: *ModelType,
workspace: WorkspaceLocationType,
first: TabLocationType,
second: TabLocationType,
tabs: [1]WorkspaceTabInputType,

pub fn init() !TestingModel {
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
    _ = try model.workspace.addCreated(.{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });

    return .{
        .model = model,
        .workspace = workspace,
        .first = first,
        .second = second,
        .tabs = .{.{
            .tab_id = first.tab_id,
            .pane_count = 1,
            .label = "main",
        }},
    };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}

pub fn snapshot(testing: *const TestingModel) WorkspaceSnapshotInput {
    return .{
        .workspace = testing.workspace,
        .name = "renamed",
        .tabs = &testing.tabs,
    };
}
