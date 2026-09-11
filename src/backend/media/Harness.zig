const Harness = @This();
const media = @import("root.zig");
const std = @import("std");
const core = @import("telar-core");
const source_namespace = @import("png_test.zig");
const vt = @import("ghostty-vt");
pipeline: media.Pipeline,
budget: media.GraphicsBudget,
allocator: media.PaneMediaAllocator,
ingestion: media.Ingestion = .{},
replies: [1024]u8 = undefined,
reply_len: usize = 0,

pub fn create(storage_limit: usize) !*Harness {
    const harness = try std.testing.allocator.create(Harness);
    errdefer std.testing.allocator.destroy(harness);
    harness.* = .{
        .pipeline = undefined,
        .budget = .init(core.graphics.max_image_bytes_global),
        .allocator = undefined,
    };
    harness.allocator = .init(std.testing.allocator, &harness.budget, core.graphics.max_image_bytes_per_pane);
    try harness.pipeline.init(.{
        .io = std.testing.io,
        .allocator = harness.allocator.allocator(),
        .size = source_namespace.size,
        .storage_limit = storage_limit,
        .payload_limit = core.graphics.max_encoded_chunk_bytes,
        .write_pty = writePty,
    });
    return harness;
}

pub fn destroy(harness: *Harness) void {
    harness.ingestion.prepared_transfers.discardAll(&harness.allocator);
    harness.ingestion.transfer_preparation.deinit(&harness.allocator);
    harness.pipeline.deinit();
    std.debug.assert(harness.budget.used == 0);
    std.testing.allocator.destroy(harness);
}

pub fn feed(harness: *Harness, bytes: []const u8) void {
    harness.pipeline.queueOutput(bytes);
    std.debug.assert(harness.pipeline.seal());
    defer harness.pipeline.finishSealed();

    var processor: media.Processor = .{
        .state = &harness.ingestion,
        .media = &harness.pipeline,
        .media_allocator = &harness.allocator,
        .graphics_limits = .{},
        .graphics_storage_limit = harness.pipeline.storage_limit,
        .io = std.testing.io,
        .responses = .{ .context = harness, .write_fn = writeResponse },
    };
    var stats: media.Stats = .{};
    processor.processMedia(source_namespace.size, &stats);
    std.debug.assert(!stats.failed);
}

fn writePty(handler: *vt.TerminalStream.Handler, response: [:0]const u8) void {
    const stream: *vt.TerminalStream = @fieldParentPtr("handler", handler);
    const pipeline: *media.Pipeline = @fieldParentPtr("stream", stream);
    const harness: *Harness = @fieldParentPtr("pipeline", pipeline);
    writeResponse(harness, response);
}

fn writeResponse(context: *anyopaque, response: []const u8) void {
    const harness: *Harness = @ptrCast(@alignCast(context));
    @memcpy(harness.replies[harness.reply_len..][0..response.len], response);
    harness.reply_len += response.len;
}

pub fn expectImage(harness: *Harness) !void {
    const storage = &harness.pipeline.terminal.screens.active.kitty_images;
    const image = storage.imageById(7) orelse return error.MissingPngImage;
    try std.testing.expectEqual(.rgba, image.format);
    try std.testing.expectEqual(@as(u32, 1), image.width);
    try std.testing.expectEqual(@as(u32, 1), image.height);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255 }, image.data.bytes().?);
    try std.testing.expectEqual(@as(usize, 1), storage.placements.count());
    try std.testing.expectEqual(@as(u16, 3), harness.pipeline.terminal.screens.active.cursor.x);
    try std.testing.expectEqual(@as(u16, 2), harness.pipeline.terminal.screens.active.cursor.y);
}
