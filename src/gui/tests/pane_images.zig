const std = @import("std");
const cellgrid = @import("cellgrid");
const client = @import("telar-client");
const core = @import("telar-core");
const data = @import("model");
const gfx = @import("gfx");
const kitty_protocol = @import("kitty_protocol");
const PaneImages = @import("../image/PaneImages.zig");
const GpuImages = @import("../image/GpuImages.zig");
const pane_images = @import("../image/pane_images.zig");
const ImageUpload = @import("../native/ImageUpload.zig");
const native = @import("../native/native.zig");
const Renderer = @import("../render/TerminalRenderer.zig");
const ImageView = @import("../image/ImageView.zig");

const Store = client.retained_graphics.Store;
const pane_id: core.PaneId = @enumFromInt(1);
const view: ImageView = .{
    .machine = 0,
    .cell_width = 10,
    .cell_height = 20,
};

fn receiveImage(store: *Store, image_id: u32, generation: u64) !void {
    const pixels = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    const key: core.ImageKey = .{
        .image_id = image_id,
        .generation = generation,
    };
    try store.applyImage(.{
        .pane_id = pane_id,
        .revision = 1,
        .image = .{
            .key = key,
            .format = .rgb,
            .width = 2,
            .height = 2,
            .byte_len = pixels.len,
        },
    });
    try store.applyChunk(.{
        .pane_id = pane_id,
        .revision = 1,
        .key = key,
        .offset = 0,
        .bytes = &pixels,
    });
}

fn receivePlacement(store: *Store, value: core.Placement) !void {
    try store.applyPlacement(.{
        .pane_id = pane_id,
        .revision = 1,
        .placement = value,
    });
}

fn placement(image_id: u32, generation: u64, virtual_id: u64, z_index: i32) core.Placement {
    return .{
        .key = .{
            .image_id = image_id,
            .generation = generation,
        },
        .virtual_id = virtual_id,
        .placement_id = 0,
        .x = 1,
        .y = 0,
        .z_index = z_index,
    };
}

// Resolves, uploads and reports every pending upload as done.
fn settle(images: *PaneImages, stores: []Store) void {
    pane_images.place(images, stores, view, 0);
    pane_images.start(images, stores, view.machine, 0);
    var frame: native.Frame = .{
        .quads = null,
        .quad_count = 0,
        .atlas = null,
        .atlas_side = 0,
        .atlas_version = 0,
        .background = @splat(0),
    };
    pane_images.handOff(images, &frame);
    for (frame.image_uploads.?[0..frame.image_upload_count]) |upload| {
        _ = pane_images.finish(images, stores, upload.handle, true, 0);
    }

    pane_images.place(images, stores, view, 0);
}

test "a placement uploads once and then draws its texture at natural size" {
    var stores = [_]Store{.init(std.testing.allocator)};
    defer stores[0].deinit();
    var images: PaneImages = .{};
    try receiveImage(&stores[0], 7, 1);
    try receivePlacement(&stores[0], placement(7, 1, 1, -1));

    pane_images.place(&images, &stores, view, 0);
    try std.testing.expectEqual(@as(usize, 1), images.placement_count);
    try std.testing.expectEqual(@as(u32, 0), images.placements[0].handle);
    try std.testing.expectEqual(kitty_protocol.Layer.below_text, images.placements[0].layer);

    pane_images.start(&images, &stores, view.machine, 0);
    try std.testing.expectEqual(@as(u32, 1), images.upload_count);
    const upload = images.uploads[0];
    try std.testing.expectEqual(@as(u32, 3), upload.bytes_per_pixel);
    try std.testing.expectEqual(@as(u32, 2), upload.width);
    try std.testing.expectEqual(@as(u8, 1), upload.pixels[0]);

    // A second prepare while the upload runs starts nothing new.
    var frame: native.Frame = .{
        .quads = null,
        .quad_count = 0,
        .atlas = null,
        .atlas_side = 0,
        .atlas_version = 0,
        .background = @splat(0),
    };
    pane_images.handOff(&images, &frame);
    try std.testing.expectEqual(@as(u32, 1), frame.image_upload_count);
    try std.testing.expectEqual(@as(u32, 0), images.upload_count);
    pane_images.place(&images, &stores, view, 0);
    pane_images.start(&images, &stores, view.machine, 0);
    try std.testing.expectEqual(@as(u32, 0), images.upload_count);

    _ = pane_images.finish(&images, &stores, upload.handle, true, 0);
    pane_images.place(&images, &stores, view, 0);
    try std.testing.expectEqual(upload.handle, images.placements[0].handle);
    try std.testing.expectEqual([4]f32{ 0, 0, 1, 1 }, images.placements[0].uv);
    try std.testing.expectEqual(@as(u32, 2), images.placements[0].box.width);
    try std.testing.expectEqual(@as(usize, 2 * 2 * 4), images.gpu.resident_bytes);
}

test "a new generation keeps drawing the previous texture until its own is ready" {
    var stores = [_]Store{.init(std.testing.allocator)};
    defer stores[0].deinit();
    var images: PaneImages = .{};
    try receiveImage(&stores[0], 7, 1);
    try receivePlacement(&stores[0], placement(7, 1, 1, 0));
    settle(&images, &stores);
    const first = images.placements[0].handle;
    try std.testing.expect(first != 0);

    try receiveImage(&stores[0], 7, 2);
    try receivePlacement(&stores[0], placement(7, 2, 1, 0));
    pane_images.place(&images, &stores, view, 0);
    try std.testing.expectEqual(first, images.placements[0].handle);
    try std.testing.expectEqual(@as(u32, 0), images.release_count);

    pane_images.start(&images, &stores, view.machine, 0);
    try std.testing.expectEqual(@as(u32, 1), images.upload_count);
    const second = images.uploads[0].handle;
    try std.testing.expect(second != first);
    _ = pane_images.finish(&images, &stores, second, true, 0);
    pane_images.place(&images, &stores, view, 0);
    try std.testing.expectEqual(second, images.placements[0].handle);
    // The replaced texture waits as a spare for the next generation.
    try std.testing.expectEqual(@as(u32, 0), images.release_count);
    try std.testing.expectEqual(@as(usize, 1), images.gpu.spares);
    try std.testing.expectEqual(GpuImages.Residency.spare, images.gpu.residency[first - 1]);

    // Generation 3 has the same size: it reuses that spare's handle.
    try receiveImage(&stores[0], 7, 3);
    try receivePlacement(&stores[0], placement(7, 3, 1, 0));
    pane_images.place(&images, &stores, view, 0);
    pane_images.start(&images, &stores, view.machine, 0);
    try std.testing.expectEqual(first, images.uploads[images.upload_count - 1].handle);
    try std.testing.expectEqual(@as(usize, 2 * 2 * 4 * 2), images.gpu.resident_bytes);
    pane_images.abandon(&images, &stores);
}

test "uploads stay within the in-flight bound" {
    var stores = [_]Store{.init(std.testing.allocator)};
    defer stores[0].deinit();
    var images: PaneImages = .{};
    for (1..ImageUpload.uploads_in_flight + 2) |id| {
        try receiveImage(&stores[0], @intCast(id), 1);
        try receivePlacement(&stores[0], placement(@intCast(id), 1, id, 0));
    }

    pane_images.place(&images, &stores, view, 0);
    pane_images.start(&images, &stores, view.machine, 0);
    try std.testing.expectEqual(@as(u32, ImageUpload.uploads_in_flight), images.upload_count);
    pane_images.abandon(&images, &stores);
}

test "a deleted image releases its texture and returns its pixels" {
    var stores = [_]Store{.init(std.testing.allocator)};
    defer stores[0].deinit();
    var images: PaneImages = .{};
    try receiveImage(&stores[0], 7, 1);
    try receivePlacement(&stores[0], placement(7, 1, 1, 0));
    settle(&images, &stores);
    const handle = images.placements[0].handle;

    try stores[0].deleteImage(.{
        .pane_id = pane_id,
        .revision = 1,
        .key = .{
            .image_id = 7,
            .generation = 1,
        },
    });
    pane_images.place(&images, &stores, view, 0);
    try std.testing.expectEqual(@as(usize, 0), images.placement_count);
    try std.testing.expectEqual(@as(usize, 0), stores[0].total_bytes);
    // Kept as a spare, still charged, until nobody reuses it for a while.
    try std.testing.expectEqual(@as(u32, 0), images.release_count);
    try std.testing.expectEqual(@as(usize, 16), images.gpu.resident_bytes);
    try std.testing.expect(pane_images.wakeupAfter(&images, 0) > 0);
    try std.testing.expect(!pane_images.trimDue(&images, 0));
    const later = 3 * std.time.ns_per_s;
    try std.testing.expect(pane_images.trimDue(&images, later));
    pane_images.place(&images, &stores, view, later);
    try std.testing.expectEqual(@as(u32, 1), images.release_count);
    try std.testing.expectEqual(handle, images.releases[0]);
    try std.testing.expectEqual(@as(usize, 0), images.gpu.resident_bytes);
    try std.testing.expectEqual(@as(u32, 0), pane_images.wakeupAfter(&images, later));
}

test "a pixel lease survives a pane clear until its upload reports" {
    var stores = [_]Store{.init(std.testing.allocator)};
    defer stores[0].deinit();
    var images: PaneImages = .{};
    try receiveImage(&stores[0], 7, 1);
    try receivePlacement(&stores[0], placement(7, 1, 1, 0));
    pane_images.place(&images, &stores, view, 0);
    pane_images.start(&images, &stores, view.machine, 0);
    const handle = images.uploads[0].handle;

    stores[0].clearPane(pane_id);
    try std.testing.expectEqual(@as(usize, 12), stores[0].total_bytes);
    _ = pane_images.finish(&images, &stores, handle, true, 0);
    try std.testing.expectEqual(@as(usize, 0), stores[0].total_bytes);
    pane_images.place(&images, &stores, view, 0);
    try std.testing.expectEqual(@as(usize, 1), images.gpu.spares);
}

test "a failed upload draws nothing and is not retried for the same image" {
    var stores = [_]Store{.init(std.testing.allocator)};
    defer stores[0].deinit();
    var images: PaneImages = .{};
    try receiveImage(&stores[0], 7, 1);
    try receivePlacement(&stores[0], placement(7, 1, 1, 0));
    pane_images.place(&images, &stores, view, 0);
    pane_images.start(&images, &stores, view.machine, 0);
    _ = pane_images.finish(&images, &stores, images.uploads[0].handle, false, 0);
    images.upload_count = 0;

    pane_images.place(&images, &stores, view, 0);
    pane_images.start(&images, &stores, view.machine, 0);
    try std.testing.expectEqual(@as(u32, 0), images.upload_count);
    try std.testing.expectEqual(@as(u32, 0), images.placements[0].handle);
    try std.testing.expectEqual(@as(usize, 0), images.gpu.resident_bytes);
}

test "hidden panes resolve no placements" {
    var stores = [_]Store{.init(std.testing.allocator)};
    defer stores[0].deinit();
    var images: PaneImages = .{};
    try receiveImage(&stores[0], 7, 1);
    try receivePlacement(&stores[0], placement(7, 1, 1, 0));
    try stores[0].setPaneVisible(pane_id, false);
    pane_images.place(&images, &stores, view, 0);
    try std.testing.expectEqual(@as(usize, 0), images.placement_count);
}

test "a full frame keeps the placements painted highest and counts the rest" {
    var stores = [_]Store{.init(std.testing.allocator)};
    defer stores[0].deinit();
    const images = try std.testing.allocator.create(PaneImages);
    defer std.testing.allocator.destroy(images);
    images.* = .{};
    const per_pane = core.max_placements_per_pane;
    const panes = PaneImages.capacity / per_pane + 1;
    const pixels = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    const key: core.ImageKey = .{
        .image_id = 7,
        .generation = 1,
    };
    for (1..panes + 1) |number| {
        const pane: core.PaneId = @enumFromInt(number);
        try stores[0].applyImage(.{
            .pane_id = pane,
            .revision = 1,
            .image = .{
                .key = key,
                .format = .rgb,
                .width = 2,
                .height = 2,
                .byte_len = pixels.len,
            },
        });
        try stores[0].applyChunk(.{
            .pane_id = pane,
            .revision = 1,
            .key = key,
            .offset = 0,
            .bytes = &pixels,
        });
        for (0..per_pane) |index| {
            var value = placement(7, 1, index + 1, if (number == 1) -5 else @intCast(index));
            value.placement_id = @intCast(index + 1);
            try stores[0].applyPlacement(.{
                .pane_id = pane,
                .revision = 1,
                .placement = value,
            });
        }
    }

    pane_images.place(images, &stores, view, 0);
    try std.testing.expectEqual(@as(usize, PaneImages.capacity), images.placement_count);
    try std.testing.expectEqual(@as(usize, panes * per_pane - PaneImages.capacity), images.dropped);
    for (images.resolved()) |kept| {
        try std.testing.expect(kept.z_index >= 0);
    }
}

test "the three layers paint around cell backgrounds and text, clipped and scrolled with the pane" {
    var stores = [_]Store{.init(std.testing.allocator)};
    defer stores[0].deinit();
    var images: PaneImages = .{};
    try receiveImage(&stores[0], 7, 1);
    try receivePlacement(&stores[0], placement(7, 1, 1, kitty_protocol.below_background_limit - 1));
    try receivePlacement(&stores[0], placement(7, 1, 2, -1));
    try receivePlacement(&stores[0], placement(7, 1, 3, 0));

    var renderer = Renderer.init(std.testing.allocator);
    defer renderer.deinit();
    _ = try renderer.measure(.{ .width = 400, .height = 300, .scale = 1 });
    const size = try renderer.measure(.{ .width = 400, .height = 300, .scale = 1 });
    const cell_view: ImageView = .{
        .machine = 0,
        .cell_width = renderer.metrics.cell_width,
        .cell_height = renderer.metrics.cell_height,
    };
    pane_images.place(&images, &stores, cell_view, 0);
    pane_images.start(&images, &stores, 0, 0);
    _ = pane_images.finish(&images, &stores, images.uploads[0].handle, true, 0);
    pane_images.place(&images, &stores, cell_view, 0);

    var pane = try data.Pane.init(std.testing.allocator, .{
        .spec = .{
            .pane_id = pane_id,
            .location = .{
                .workspace = .{
                    .workspace = @enumFromInt(1),
                },
                .tab_id = @enumFromInt(1),
            },
            .size = size,
        },
        .attached = true,
    });
    defer pane.deinit();
    for (pane.buffer.cells) |*cell| {
        cell.* = .{};
    }

    pane.buffer.cells[1].bytes[0] = 'a';
    pane.buffer.cells[1].len = 1;
    pane.buffer.cells[1].style.bg = .rgb(.{ 200, 0, 0 });
    pane.scroll = .{
        .total_rows = @as(u32, pane.buffer.h) + 10,
        .offset = 7,
    };
    const area: cellgrid.Rect = .{
        .w = size.cols,
        .h = size.rows,
    };

    renderer.begin();
    renderer.images = images.resolved();
    try renderer.drawPane(.{
        .pane = &pane,
        .view = .{
            .pane_id = pane_id,
            .outer = area,
            .content = area,
            .focused = false,
            .display_index = 1,
        },
        .hide_cursor = true,
    });

    const draws = renderer.imageDraws();
    const quads = renderer.quads.items();
    try std.testing.expectEqual(@as(usize, 3), draws.len);
    try std.testing.expectEqual(@as(u32, 0), draws[0].quad);
    try std.testing.expect(draws[1].quad > draws[0].quad + 1);
    try std.testing.expect(draws[2].quad > draws[1].quad + 1);
    for (draws) |draw| {
        try std.testing.expectEqual(gfx.Quad.image_texture, quads[draw.quad].texture);
    }

    // Scrolled back three rows: the row-0 placement shows three rows down.
    const bounds = renderer.metrics.rect(renderer.origin, area);
    const cell_width: f32 = @floatFromInt(renderer.metrics.cell_width);
    const cell_height: f32 = @floatFromInt(renderer.metrics.cell_height);
    try std.testing.expectEqual(bounds.x + cell_width, quads[draws[0].quad].x);
    try std.testing.expectEqual(bounds.y + 3 * cell_height, quads[draws[0].quad].y);
    try std.testing.expectEqual(@as(f32, 2), quads[draws[0].quad].width);

    // Scrolled back past it, nothing is drawn and no draw is recorded.
    pane.scroll.total_rows = @as(u32, pane.buffer.h) + 1000;
    pane.scroll.offset = 0;
    renderer.begin();
    try renderer.drawPane(.{
        .pane = &pane,
        .view = .{
            .pane_id = pane_id,
            .outer = area,
            .content = area,
            .focused = false,
            .display_index = 1,
        },
        .hide_cursor = true,
    });
    try std.testing.expectEqual(@as(usize, 0), renderer.imageDraws().len);
}

test "a stream uploads its next generation while the previous one finishes, never a third" {
    var stores = [_]Store{.init(std.testing.allocator)};
    defer stores[0].deinit();
    var images: PaneImages = .{};
    try receiveImage(&stores[0], 7, 1);
    try receivePlacement(&stores[0], placement(7, 1, 1, 0));
    pane_images.place(&images, &stores, view, 0);
    pane_images.start(&images, &stores, view.machine, 0);
    try std.testing.expectEqual(@as(u32, 1), images.upload_count);

    try receiveImage(&stores[0], 7, 2);
    try receivePlacement(&stores[0], placement(7, 2, 1, 0));
    pane_images.place(&images, &stores, view, 0);
    pane_images.start(&images, &stores, view.machine, 0);
    try std.testing.expectEqual(@as(u32, 2), images.upload_count);

    try receiveImage(&stores[0], 7, 3);
    try receivePlacement(&stores[0], placement(7, 3, 1, 0));
    pane_images.place(&images, &stores, view, 0);
    pane_images.start(&images, &stores, view.machine, 0);
    try std.testing.expectEqual(@as(u32, 2), images.upload_count);
    pane_images.abandon(&images, &stores);
}

test "a placement shows the newest complete generation that arrived before its own update" {
    var stores = [_]Store{.init(std.testing.allocator)};
    defer stores[0].deinit();
    var images: PaneImages = .{};
    try receiveImage(&stores[0], 7, 1);
    try receivePlacement(&stores[0], placement(7, 1, 1, 0));
    // Generation 2 arrives; the placement still names generation 1.
    try receiveImage(&stores[0], 7, 2);

    pane_images.place(&images, &stores, view, 0);
    pane_images.start(&images, &stores, view.machine, 0);
    try std.testing.expectEqual(@as(u32, 1), images.upload_count);
    const upload = images.uploads[0];
    _ = pane_images.finish(&images, &stores, upload.handle, true, 0);
    pane_images.place(&images, &stores, view, 0);
    try std.testing.expectEqual(upload.handle, images.placements[0].handle);
    try std.testing.expectEqual(@as(u64, 2), images.gpu.identity[upload.handle - 1].generation);
}

test "a texture no frame draws for a while is released, as a hidden tab's" {
    var stores = [_]Store{.init(std.testing.allocator)};
    defer stores[0].deinit();
    var images: PaneImages = .{};
    try receiveImage(&stores[0], 7, 1);
    try receivePlacement(&stores[0], placement(7, 1, 1, 0));
    settle(&images, &stores);
    try stores[0].setPaneVisible(pane_id, false);
    const later = 6 * std.time.ns_per_s;
    try std.testing.expect(pane_images.trimDue(&images, later));
    pane_images.place(&images, &stores, view, later);
    try std.testing.expectEqual(@as(u32, 1), images.release_count);
    try std.testing.expectEqual(@as(usize, 0), images.gpu.count);
    // Its pixels stay in the store for a re-upload when the tab returns.
    try std.testing.expectEqual(@as(usize, 12), stores[0].total_bytes);
}

test "textures and retained pixels share one quota" {
    var stores = [_]Store{.init(std.testing.allocator)};
    defer stores[0].deinit();
    var images: PaneImages = .{};
    try receiveImage(&stores[0], 7, 1);
    try receivePlacement(&stores[0], placement(7, 1, 1, 0));
    images.gpu.resident_bytes = GpuImages.budget - stores[0].total_bytes - 1;
    pane_images.place(&images, &stores, view, 0);
    pane_images.start(&images, &stores, view.machine, 0);
    try std.testing.expectEqual(@as(u32, 0), images.upload_count);
    images.gpu.resident_bytes = 0;
}

test "a texture that just became ready survives the next frame on a real clock" {
    var stores = [_]Store{.init(std.testing.allocator)};
    defer stores[0].deinit();
    var images: PaneImages = .{};
    try receiveImage(&stores[0], 7, 1);
    try receivePlacement(&stores[0], placement(7, 1, 1, 0));
    // A monotonic clock days past its epoch.
    const now = 2_000_000 * std.time.ns_per_s;
    pane_images.place(&images, &stores, view, now);
    pane_images.start(&images, &stores, view.machine, now);
    _ = pane_images.finish(&images, &stores, images.uploads[0].handle, true, now + std.time.ns_per_ms);
    pane_images.place(&images, &stores, view, now + 2 * std.time.ns_per_ms);
    try std.testing.expect(images.placements[0].handle != 0);
    try std.testing.expectEqual(@as(u32, 0), images.release_count);
}
