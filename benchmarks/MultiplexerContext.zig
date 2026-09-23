const data = @import("model");
const client = @import("telar-client");
const frontend = @import("telar-frontend");
const core = @import("telar-core");
const std = @import("std");
const main = @import("main.zig");
const MultiplexerContext = @This();

model: data.ClientModel,
screen: frontend.Screen,
compositor: frontend.Compositor,

pub fn init(gpa: std.mem.Allocator) !MultiplexerContext {
    var model = data.ClientModel.init(gpa, true);
    errdefer model.deinit();
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try data.workspace_handoff.bootstrap(&model, .{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = main.cols, .rows = main.rows } });
    const area: core.Rect = .{ .w = main.cols, .h = main.rows };
    try data.pane_split.split(&model, 0, .{ .existing_pane = @enumFromInt(1), .new_pane = @enumFromInt(2), .location = location, .axis = .horizontal, .area = area });
    try data.pane_split.split(&model, 0, .{ .existing_pane = @enumFromInt(1), .new_pane = @enumFromInt(3), .location = location, .axis = .vertical, .area = area });
    try data.pane_split.split(&model, 0, .{ .existing_pane = @enumFromInt(2), .new_pane = @enumFromInt(4), .location = location, .axis = .vertical, .area = area });
    var panes = model.panes.iterate(null);
    while (panes.next()) |pane| {
        pane.buffer.setCell(.{ .x = 0, .y = 0 }, .{ .text = "x" });
    }
    const screen = try frontend.Screen.init(gpa, main.cols, main.rows);
    return .{ .model = model, .screen = screen, .compositor = .init(gpa) };
}

pub fn deinit(context: *MultiplexerContext) void {
    context.compositor.deinit();
    context.screen.deinit();
    context.model.deinit();
}
