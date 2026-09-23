const core = @import("telar-core");
const Pipeline = @import("Pipeline.zig");
const GraphicsBudget = @import("GraphicsBudget.zig");
const PaneMediaAllocator = @import("PaneMediaAllocator.zig");
const State = @import("State.zig");
const std = @import("std");
const png_test = @import("png_test.zig");
const Processor = @import("Processor.zig");
const Stats = @import("Stats.zig");
const vt = @import("ghostty-vt");
const Harness = @This();

pipeline: Pipeline,
budget: GraphicsBudget,
allocator: PaneMediaAllocator,
ingestion: State = .{},
replies: [1024]u8 = undefined,
reply_len: usize = 0,

pub fn create(storage_limit: usize) !*Harness {
    const harness = try std.testing.allocator.create(Harness);
    errdefer std.testing.allocator.destroy(harness);
    harness.* = .{
        .pipeline = undefined,
        .budget = .init(core.max_image_bytes_global),
        .allocator = undefined,
    };
    harness.allocator = .init(std.testing.allocator, &harness.budget, core.max_image_bytes_per_pane);
    try harness.pipeline.init(.{
        .io = std.testing.io,
        .allocator = harness.allocator.allocator(),
        .size = png_test.size,
        .storage_limit = storage_limit,
        .payload_limit = core.max_encoded_chunk_bytes,
        .write_pty = writePty,
    });
    return harness;
}

pub fn destroy(self: *Harness) void {
    self.ingestion.prepared_transfers.discardAll(&self.allocator);
    self.ingestion.transfer_preparation.deinit(&self.allocator);
    self.pipeline.deinit();
    std.debug.assert(self.budget.used == 0);
    std.testing.allocator.destroy(self);
}

pub fn feed(self: *Harness, bytes: []const u8) void {
    self.pipeline.queueOutput(bytes);
    std.debug.assert(self.pipeline.seal());
    defer self.pipeline.finishSealed();

    var processor: Processor = .{
        .state = &self.ingestion,
        .media = &self.pipeline,
        .media_allocator = &self.allocator,
        .graphics_limits = .{},
        .graphics_storage_limit = self.pipeline.storage_limit,
        .io = std.testing.io,
        .responses = .{ .context = self, .write_fn = writeResponse },
    };
    var stats: Stats = .{};
    processor.processMedia(png_test.size, &stats);
    std.debug.assert(!stats.failed);
}

fn writePty(handler: *vt.TerminalStream.Handler, response: [:0]const u8) void {
    const stream: *vt.TerminalStream = @fieldParentPtr("handler", handler);
    const pipeline: *Pipeline = @fieldParentPtr("stream", stream);
    const harness: *Harness = @fieldParentPtr("pipeline", pipeline);
    writeResponse(harness, response);
}

fn writeResponse(context: *anyopaque, response: []const u8) void {
    const harness: *Harness = @ptrCast(@alignCast(context));
    @memcpy(harness.replies[harness.reply_len..][0..response.len], response);
    harness.reply_len += response.len;
}

pub fn expectImage(self: *Harness) !void {
    const storage = &self.pipeline.terminal.screens.active.kitty_images;
    const image = storage.imageById(7) orelse return error.MissingPngImage;
    try std.testing.expectEqual(.rgba, image.format);
    try std.testing.expectEqual(@as(u32, 1), image.width);
    try std.testing.expectEqual(@as(u32, 1), image.height);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255 }, image.data.bytes().?);
    try std.testing.expectEqual(@as(usize, 1), storage.placements.count());
    try std.testing.expectEqual(@as(u16, 3), self.pipeline.terminal.screens.active.cursor.x);
    try std.testing.expectEqual(@as(u16, 2), self.pipeline.terminal.screens.active.cursor.y);
}
