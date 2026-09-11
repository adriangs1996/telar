const GraphicsContext = @This();
const frontend = @import("telar-frontend");
const std = @import("std");
const source_namespace = @import("main.zig");
const core = @import("telar-core");
store: frontend.kitty.Store,
model: frontend.multiplexer.Model,
output: []u8,

fn init(gpa: std.mem.Allocator, output: []u8) !GraphicsContext {
    var store = frontend.kitty.Store.init(gpa);
    errdefer store.deinit();
    var model = frontend.multiplexer.Model.init(gpa);
    errdefer model.deinit();
    const pane_id: source_namespace.schema.PaneId = @enumFromInt(1);
    try model.addRoot(.{
        .pane_id = pane_id,
        .location = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(1) },
        .size = .{ .cols = source_namespace.cols, .rows = source_namespace.rows },
    });
    const metadata: core.graphics.Image = .{
        .key = .{ .image_id = 1, .generation = 1 },
        .format = .rgba,
        .width = 64,
        .height = 64,
        .byte_len = 64 * 64 * 4,
    };
    try store.applyImage(.{ .pane_id = pane_id, .revision = 1, .image = metadata });
    var pixels: [64 * 64 * 4]u8 = undefined;
    for (&pixels, 0..) |*byte, index| byte.* = @truncate(index);
    try store.applyChunk(.{
        .pane_id = pane_id,
        .revision = 1,
        .key = metadata.key,
        .offset = 0,
        .bytes = &pixels,
    });
    try store.applyPlacement(.{
        .pane_id = pane_id,
        .revision = 1,
        .placement = .{
            .key = metadata.key,
            .virtual_id = 1,
            .placement_id = 1,
            .x = 0,
            .y = 0,
        },
    });
    return .{ .store = store, .model = model, .output = output };
}

fn deinit(context: *GraphicsContext) void {
    context.model.deinit();
    context.store.deinit();
}

fn writer(context: *GraphicsContext) frontend.kitty.KittyGraphicsWriter {
    return .{
        .store = &context.store,
        .layout_snapshot = context.model.layoutSnapshot(.{ .w = source_namespace.cols, .h = source_namespace.rows }),
        .cell_width = 10,
        .cell_height = 20,
    };
}
