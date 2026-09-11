const std = @import("std");
const StoreType = @import("telar-frontend").Store;
const MultiplexerModel = @import("telar-client").MultiplexerModel;
const PaneIdType = @import("telar-core").PaneId;
const main = @import("main.zig");
const ImageType = @import("telar-core").Image;
const KittyGraphicsWriterType = @import("telar-frontend").KittyGraphicsWriter;
/// A full inline delivery of one browser-frame-sized image: the media path's
/// unit of throughput. One op is every writer pass an unbounded budget needs
/// until the store goes idle, so the zlib variant includes its deflate.
const TransmitContext = @This();

const width = 480;
const height = 360;
const raw_len = width * height * 4;

gpa: std.mem.Allocator,
store: StoreType,
model: MultiplexerModel,
output: []u8,

pub fn init(gpa: std.mem.Allocator, zlib: bool) !TransmitContext {
    var store = StoreType.init(gpa);
    errdefer store.deinit();
    store.delivery.host_zlib = zlib;
    var model = MultiplexerModel.init(gpa);
    errdefer model.deinit();
    const pane_id: PaneIdType = @enumFromInt(1);
    try model.addRoot(.{
        .pane_id = pane_id,
        .location = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(1) },
        .size = .{ .cols = main.cols, .rows = main.rows },
    });

    // Browser-frame shape: flat fills, a gradient, and a text-like band
    // of sparse noise. Pure random would defeat the zlib variant, pure
    // flat would flatter it.
    const pixels = try gpa.alloc(u8, raw_len);
    defer gpa.free(pixels);
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    for (0..height) |y| {
        for (0..width) |x| {
            const index = (y * width + x) * 4;
            if (y % 40 < 28) {
                pixels[index + 0] = @intCast(30 + (x * 40) / width);
                pixels[index + 1] = 34;
                pixels[index + 2] = 40;
            } else {
                const value: u8 = if (random.uintLessThan(u8, 8) == 0) 220 else 24;
                pixels[index + 0] = value;
                pixels[index + 1] = value;
                pixels[index + 2] = value;
            }
            pixels[index + 3] = 255;
        }
    }
    const metadata: ImageType = .{
        .key = .{ .image_id = 1, .generation = 1 },
        .format = .rgba,
        .width = width,
        .height = height,
        .byte_len = raw_len,
    };
    try store.applyImage(.{ .pane_id = pane_id, .revision = 1, .image = metadata });
    try store.applyChunk(.{
        .pane_id = pane_id,
        .revision = 1,
        .key = metadata.key,
        .offset = 0,
        .bytes = pixels,
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
    const output = try gpa.alloc(u8, 4 * 1024 * 1024);
    return .{ .gpa = gpa, .store = store, .model = model, .output = output };
}

pub fn deinit(context: *TransmitContext) void {
    context.gpa.free(context.output);
    context.model.deinit();
    context.store.deinit();
}

pub fn deliver(context: *TransmitContext) !u64 {
    var images = context.store.images.iterator();
    while (images.next()) |entry| {
        entry.value_ptr.delivery.transmitted = false;
        entry.value_ptr.delivery.incompressible = false;
    }

    var placements = context.store.placements.iterator();
    while (placements.next()) |entry| {
        entry.value_ptr.delivery.emitted_image_id = null;
        entry.value_ptr.delivery.dirty = true;
    }
    context.store.damage = true;
    var written: u64 = 0;
    while (context.store.damage) {
        var output = std.Io.Writer.fixed(context.output);
        var graphics_writer: KittyGraphicsWriterType = .{
            .store = &context.store,
            .layout_snapshot = context.model.layoutSnapshot(.{ .w = main.cols, .h = main.rows }),
            .cell_width = 10,
            .cell_height = 20,
            .budget = std.math.maxInt(usize),
        };
        written += try graphics_writer.write(&output);
    }
    return written;
}
