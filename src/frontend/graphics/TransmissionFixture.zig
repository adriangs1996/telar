const data = @import("model");
const core = @import("telar-core");
const client = @import("telar-client");
const kitty_delivery = @import("kitty_delivery.zig");
const std = @import("std");
const KittyGraphicsWriter = @import("KittyGraphicsWriter.zig");
/// One pane holding a complete 512x256 RGBA image with one placement, the
/// shape the budget and compression tests all exercise.
const TransmissionFixture = @This();

pub const metadata: core.Image = .{
    .key = .{ .image_id = 1, .generation = 1 },
    .format = .rgba,
    .width = 512,
    .height = 256,
    .byte_len = 512 * 256 * 4,
};

model: data.ClientModel,
store: kitty_delivery.Store,

pub fn init(pixels: []const u8) !TransmissionFixture {
    std.debug.assert(pixels.len == metadata.byte_len);
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    var model = data.ClientModel.init(std.testing.allocator, true);
    errdefer model.deinit();
    try data.workspace_handoff.bootstrap(&model, .{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 10, .rows = 5 } });
    var store = kitty_delivery.Store.init(std.testing.allocator);
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

pub fn deinit(self: *TransmissionFixture) void {
    self.store.deinit();
    self.model.deinit();
}

pub fn writer(self: *TransmissionFixture, budget: usize) KittyGraphicsWriter {
    return .{
        .store = &self.store,
        .layout_snapshot = data.tab_layout.snapshot(&self.model, 0, .{ .w = 10, .h = 5 }),
        .cell_width = 10,
        .cell_height = 20,
        .budget = budget,
    };
}
