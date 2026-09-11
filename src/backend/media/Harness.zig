const PipelineType = @import("Pipeline.zig");
const GraphicsBudgetType = @import("GraphicsBudget.zig");
const PaneMediaAllocatorType = @import("PaneMediaAllocator.zig");
const State = @import("State.zig");
const std = @import("std");
const max_image_bytes_global_module = @import("telar-core").max_image_bytes_global;
const max_image_bytes_per_pane_module = @import("telar-core").max_image_bytes_per_pane;
const png_test = @import("png_test.zig");
const max_encoded_chunk_bytes_module = @import("telar-core").max_encoded_chunk_bytes;
const ProcessorType = @import("Processor.zig");
const StatsType = @import("Stats.zig");
const vt = @import("ghostty-vt");
const Harness = @This();

pipeline: PipelineType,
budget: GraphicsBudgetType,
allocator: PaneMediaAllocatorType,
ingestion: State = .{},
replies: [1024]u8 = undefined,
reply_len: usize = 0,

pub fn create(storage_limit: usize) !*Harness {
    const harness = try std.testing.allocator.create(Harness);
    errdefer std.testing.allocator.destroy(harness);
    harness.* = .{
        .pipeline = undefined,
        .budget = .init(max_image_bytes_global_module),
        .allocator = undefined,
    };
    harness.allocator = .init(std.testing.allocator, &harness.budget, max_image_bytes_per_pane_module);
    try harness.pipeline.init(.{
        .io = std.testing.io,
        .allocator = harness.allocator.allocator(),
        .size = png_test.size,
        .storage_limit = storage_limit,
        .payload_limit = max_encoded_chunk_bytes_module,
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

    var processor: ProcessorType = .{
        .state = &harness.ingestion,
        .media = &harness.pipeline,
        .media_allocator = &harness.allocator,
        .graphics_limits = .{},
        .graphics_storage_limit = harness.pipeline.storage_limit,
        .io = std.testing.io,
        .responses = .{ .context = harness, .write_fn = writeResponse },
    };
    var stats: StatsType = .{};
    processor.processMedia(png_test.size, &stats);
    std.debug.assert(!stats.failed);
}

fn writePty(handler: *vt.TerminalStream.Handler, response: [:0]const u8) void {
    const stream: *vt.TerminalStream = @fieldParentPtr("handler", handler);
    const pipeline: *PipelineType = @fieldParentPtr("stream", stream);
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
