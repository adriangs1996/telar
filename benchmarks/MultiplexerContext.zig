const MultiplexerModel = @import("telar-client").MultiplexerModel;
const ScreenType = @import("telar-frontend").Screen;
const CompositorType = @import("telar-frontend").Compositor;
const std = @import("std");
const TabLocationType = @import("telar-core").TabLocation;
const main = @import("main.zig");
const RectType = @import("telar-core").Rect;
const MultiplexerContext = @This();

model: MultiplexerModel,
screen: ScreenType,
compositor: CompositorType,

pub fn init(gpa: std.mem.Allocator) !MultiplexerContext {
    var model = MultiplexerModel.init(gpa);
    errdefer model.deinit();
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = main.cols, .rows = main.rows } });
    const area: RectType = .{ .w = main.cols, .h = main.rows };
    try model.split(.{ .existing_pane = @enumFromInt(1), .new_pane = @enumFromInt(2), .location = location, .axis = .horizontal, .area = area });
    try model.split(.{ .existing_pane = @enumFromInt(1), .new_pane = @enumFromInt(3), .location = location, .axis = .vertical, .area = area });
    try model.split(.{ .existing_pane = @enumFromInt(2), .new_pane = @enumFromInt(4), .location = location, .axis = .vertical, .area = area });
    for (&model.panes) |*slot| {
        const pane = if (slot.*) |*value| value else continue;
        pane.buffer.setCell(.{ .x = 0, .y = 0 }, .{ .text = "x" });
    }
    const screen = try ScreenType.init(gpa, main.cols, main.rows);
    return .{ .model = model, .screen = screen, .compositor = .init(gpa) };
}

pub fn deinit(context: *MultiplexerContext) void {
    context.compositor.deinit();
    context.screen.deinit();
    context.model.deinit();
}
