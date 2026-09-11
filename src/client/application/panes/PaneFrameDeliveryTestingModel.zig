const ModelType = @import("../../model/Model.zig");
const PaneIdType = @import("telar-core").PaneId;
const std = @import("std");
const TabLocationType = @import("telar-core").TabLocation;
const ScrollType = @import("telar-core").Scroll;
const PaneFrameCommitType = @import("../../model/PaneFrameCommit.zig");
const CellType = @import("telar-core").Cell;
const encodePaneFrame_module = @import("telar-core").encodePaneFrame;
const decodeServer_module = @import("telar-core").decodeServer;
const TestingModel = @This();

model: *ModelType,
pane_id: PaneIdType,

pub fn init() !TestingModel {
    const model = try std.testing.allocator.create(ModelType);
    errdefer std.testing.allocator.destroy(model);
    model.* = ModelType.init(std.testing.allocator, true);
    errdefer model.deinit();

    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: PaneIdType = @enumFromInt(1);
    try model.workspace.bootstrap(.{ .pane_id = pane_id, .location = location, .size = .{ .cols = 2, .rows = 2 } });

    return .{
        .model = model,
        .pane_id = pane_id,
    };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}

pub fn applyFrame(testing: *TestingModel, scroll: ScrollType) !PaneFrameCommitType {
    const cells = [_]CellType{ .{}, .{}, .{}, .{} };
    var encoded: [512]u8 = undefined;
    const bytes = try encodePaneFrame_module(&encoded, .{
        .pane_id = testing.pane_id,
        .frame_id = 7,
        .base_frame_id = 0,
        .cols = 2,
        .rows = 2,
        .scroll = scroll,
        .spans = &.{.{ .start = 0, .cells = &cells }},
    });
    const outcome = try testing.model.applyPaneFrame((try decodeServer_module(bytes)).pane_frame);

    return outcome.applied;
}
