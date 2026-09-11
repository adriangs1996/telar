const MultiplexerContext = @This();
const frontend = @import("telar-frontend");
const std = @import("std");
const source_namespace = @import("main.zig");
const core = @import("telar-core");
model: frontend.multiplexer.Model,
screen: frontend.term.Screen,
compositor: frontend.multiplexer.Compositor,

fn init(gpa: std.mem.Allocator) !MultiplexerContext {
    var model = frontend.multiplexer.Model.init(gpa);
    errdefer model.deinit();
    const location: source_namespace.schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = source_namespace.cols, .rows = source_namespace.rows } });
    const area: core.ui.Rect = .{ .w = source_namespace.cols, .h = source_namespace.rows };
    try model.split(.{ .existing_pane = @enumFromInt(1), .new_pane = @enumFromInt(2), .location = location, .axis = .horizontal, .area = area });
    try model.split(.{ .existing_pane = @enumFromInt(1), .new_pane = @enumFromInt(3), .location = location, .axis = .vertical, .area = area });
    try model.split(.{ .existing_pane = @enumFromInt(2), .new_pane = @enumFromInt(4), .location = location, .axis = .vertical, .area = area });
    for (&model.panes) |*slot| {
        const pane = if (slot.*) |*value| value else continue;
        pane.buffer.setCell(.{ .x = 0, .y = 0 }, .{ .text = "x" });
    }
    const screen = try frontend.term.Screen.init(gpa, source_namespace.cols, source_namespace.rows);
    return .{ .model = model, .screen = screen, .compositor = .init(gpa) };
}

fn deinit(context: *MultiplexerContext) void {
    context.compositor.deinit();
    context.screen.deinit();
    context.model.deinit();
}
