const data = @import("model");
const frontend = @import("telar-frontend");
const core = @import("telar-core");
const std = @import("std");
const main = @import("main.zig");
const GraphicsContext = @This();

store: frontend.Store,
model: *data.ClientModel,
output: []u8,

pub fn init(gpa: std.mem.Allocator, output: []u8) !GraphicsContext {
    var store = frontend.Store.init(gpa);
    errdefer store.deinit();
    const model = try gpa.create(data.ClientModel);
    errdefer gpa.destroy(model);
    model.initInto(gpa, .{ .pane_gaps = true });
    errdefer model.deinit();
    const pane_id: core.PaneId = @enumFromInt(1);
    try data.workspace_handoff.bootstrap(model, .{
        .pane_id = pane_id,
        .location = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(1) },
        .size = .{ .cols = main.cols, .rows = main.rows },
    });
    const metadata: core.Image = .{
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

pub fn deinit(self: *GraphicsContext) void {
    const model_gpa = self.model.gpa;
    self.model.deinit();
    model_gpa.destroy(self.model);
    self.store.deinit();
}

pub fn writer(self: *GraphicsContext) frontend.KittyGraphicsWriter {
    return .{
        .store = &self.store,
        .layout_snapshot = data.tab_layout.snapshot(self.model, 0, .{ .w = main.cols, .h = main.rows }),
        .cell_width = 10,
        .cell_height = 20,
    };
}
