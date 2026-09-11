const StoreType = @import("telar-frontend").Store;
const MultiplexerModel = @import("telar-client").MultiplexerModel;
const std = @import("std");
const PaneIdType = @import("telar-core").PaneId;
const main = @import("main.zig");
const ImageType = @import("telar-core").Image;
const KittyGraphicsWriterType = @import("telar-frontend").KittyGraphicsWriter;
const GraphicsContext = @This();

store: StoreType,
model: MultiplexerModel,
output: []u8,

pub fn init(gpa: std.mem.Allocator, output: []u8) !GraphicsContext {
    var store = StoreType.init(gpa);
    errdefer store.deinit();
    var model = MultiplexerModel.init(gpa);
    errdefer model.deinit();
    const pane_id: PaneIdType = @enumFromInt(1);
    try model.addRoot(.{
        .pane_id = pane_id,
        .location = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(1) },
        .size = .{ .cols = main.cols, .rows = main.rows },
    });
    const metadata: ImageType = .{
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

pub fn deinit(context: *GraphicsContext) void {
    context.model.deinit();
    context.store.deinit();
}

pub fn writer(context: *GraphicsContext) KittyGraphicsWriterType {
    return .{
        .store = &context.store,
        .layout_snapshot = context.model.layoutSnapshot(.{ .w = main.cols, .h = main.rows }),
        .cell_width = 10,
        .cell_height = 20,
    };
}
