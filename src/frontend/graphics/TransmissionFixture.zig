/// One pane holding a complete 512x256 RGBA image with one placement, the
/// shape the budget and compression tests all exercise.
const TransmissionFixture = @This();
const source_namespace = @import("kitty.zig");
const std = @import("std");
const KittyGraphicsWriter = @import("KittyGraphicsWriter.zig");
pub const metadata: source_namespace.graphics.Image = .{
    .key = .{ .image_id = 1, .generation = 1 },
    .format = .rgba,
    .width = 512,
    .height = 256,
    .byte_len = 512 * 256 * 4,
};

model: source_namespace.multiplexer.Model,
store: source_namespace.Store,

pub fn init(pixels: []const u8) !TransmissionFixture {
    std.debug.assert(pixels.len == metadata.byte_len);
    const location: source_namespace.schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    var model = source_namespace.multiplexer.Model.init(std.testing.allocator);
    errdefer model.deinit();
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 10, .rows = 5 } });
    var store = source_namespace.Store.init(std.testing.allocator);
    errdefer store.deinit();
    try store.applyImage(.{ .pane_id = @enumFromInt(1), .revision = 1, .image = metadata });
    try store.applyChunk(.{
        .pane_id = @enumFromInt(1),
        .revision = 1,
        .key = metadata.key,
        .offset = 0,
        .bytes = pixels,
    });
    try store.applyPlacement(.{
        .pane_id = @enumFromInt(1),
        .revision = 1,
        .placement = .{
            .key = metadata.key,
            .virtual_id = 1,
            .placement_id = 1,
            .x = 0,
            .y = 0,
        },
    });
    return .{ .model = model, .store = store };
}

pub fn deinit(fixture: *TransmissionFixture) void {
    fixture.store.deinit();
    fixture.model.deinit();
}

pub fn writer(fixture: *TransmissionFixture, budget: usize) KittyGraphicsWriter {
    return .{
        .store = &fixture.store,
        .layout_snapshot = fixture.model.layoutSnapshot(.{ .w = 10, .h = 5 }),
        .cell_width = 10,
        .cell_height = 20,
        .budget = budget,
    };
}
