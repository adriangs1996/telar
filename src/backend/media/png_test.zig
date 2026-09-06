const std = @import("std");
const vt = @import("ghostty-vt");
const core = @import("telar-core");
const media = @import("root.zig");

const size: core.schema.TerminalSize = .{ .cols = 10, .rows = 5, .cell_width_px = 10, .cell_height_px = 20 };
const fixture = @embedFile("testdata/rgba.png");
const encoded = &encoded_storage;
const encoded_storage = encoded: {
    var buffer: [std.base64.standard.Encoder.calcSize(fixture.len)]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&buffer, fixture);
    break :encoded buffer;
};

const Harness = struct {
    pipeline: media.Pipeline,
    budget: media.GraphicsBudget,
    allocator: media.PaneMediaAllocator,
    ingestion: media.Ingestion = .{},
    replies: [1024]u8 = undefined,
    reply_len: usize = 0,

    fn create(storage_limit: usize) !*Harness {
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
            .size = size,
            .storage_limit = storage_limit,
            .payload_limit = core.graphics.max_encoded_chunk_bytes,
            .write_pty = writePty,
        });
        return harness;
    }

    fn destroy(harness: *Harness) void {
        harness.ingestion.prepared_transfers.discardAll(&harness.allocator);
        harness.ingestion.transfer_preparation.deinit(&harness.allocator);
        harness.pipeline.deinit();
        std.debug.assert(harness.budget.used == 0);
        std.testing.allocator.destroy(harness);
    }

    fn feed(harness: *Harness, bytes: []const u8) void {
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
        processor.processMedia(size, &stats);
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

    fn expectImage(harness: *Harness) !void {
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
};

test "PNG KGP preserves chunk state across every PTY split and keeps cursor policy" {
    const bytes = try std.fmt.allocPrint(std.testing.allocator, "\x1b[3;4H\x1b_Ga=T,f=100,i=7,C=1,c=2,r=2,m=1;{s}\x1b\\\x1b_Gm=0;{s}\x1b\\", .{ encoded[0..48], encoded[48..] });
    defer std.testing.allocator.free(bytes);

    for (0..bytes.len + 1) |split| {
        const harness = try Harness.create(core.graphics.max_image_bytes_per_screen);
        defer harness.destroy();
        harness.feed(bytes[0..split]);
        harness.feed(bytes[split..]);
        try harness.expectImage();
        try std.testing.expectEqualStrings("\x1b_Gi=7;OK\x1b\\", harness.replies[0..harness.reply_len]);
    }
}

test "PNG KGP accepts Pi's 4096-character chunks and quiet anonymous placements" {
    const large = @embedFile("testdata/chunked.png");
    var base64: [std.base64.standard.Encoder.calcSize(large.len)]u8 = undefined;
    const data = std.base64.standard.Encoder.encode(&base64, large);
    try std.testing.expect(data.len > 8192);
    const harness = try Harness.create(core.graphics.max_image_bytes_per_screen);
    defer harness.destroy();
    harness.feed("\x1b[3;4H");

    var offset: usize = 0;
    while (offset < data.len) {
        const end = @min(offset + 4096, data.len);
        const header = if (offset == 0) "a=T,f=100,q=2,C=1,c=2,r=2,i=7," else "";
        const command = try std.fmt.allocPrint(std.testing.allocator, "\x1b_G{s}m={d};{s}\x1b\\", .{ header, @intFromBool(end != data.len), data[offset..end] });
        defer std.testing.allocator.free(command);
        harness.feed(command);

        if (end != data.len) {
            try std.testing.expect(harness.pipeline.terminal.screens.active.kitty_images.imageById(7) == null);
        }

        offset = end;
    }

    try harness.expectImage();
    try std.testing.expectEqual(@as(usize, 0), harness.reply_len);
    const storage = &harness.pipeline.terminal.screens.active.kitty_images;
    const generation = storage.imageById(7).?.generation;
    const replacement = try std.fmt.allocPrint(std.testing.allocator, "\x1b_Ga=T,f=100,i=7,C=1,q=2;{s}\x1b\\", .{encoded});
    defer std.testing.allocator.free(replacement);
    harness.feed(replacement);
    try std.testing.expect(storage.imageById(7).?.generation > generation);
    harness.feed("\x1b_Ga=d,d=I,i=7,q=2\x1b\\");
    try std.testing.expectEqual(@as(usize, 0), storage.images.count());
    try std.testing.expectEqual(@as(usize, 0), storage.placements.count());
}

test "PNG queries validate without storing and malformed uploads recover" {
    const previous_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = previous_log_level;
    const harness = try Harness.create(core.graphics.max_image_bytes_per_screen);
    defer harness.destroy();
    const query = try std.fmt.allocPrint(std.testing.allocator, "\x1b_Ga=q,f=100,i=7;{s}\x1b\\", .{encoded});
    defer std.testing.allocator.free(query);
    harness.feed(query);
    try std.testing.expectEqualStrings("\x1b_Gi=7;OK\x1b\\", harness.replies[0..harness.reply_len]);
    try std.testing.expectEqual(@as(usize, 0), harness.pipeline.terminal.screens.active.kitty_images.images.count());
    harness.reply_len = 0;
    harness.feed("\x1b_Ga=T,f=100,i=7;AAAA\x1b\\");
    try std.testing.expect(std.mem.indexOf(u8, harness.replies[0..harness.reply_len], "EINVAL") != null);
    harness.reply_len = 0;
    harness.feed("\x1b_Ga=T,f=100,i=7,q=2;AAAA\x1b\\");
    try std.testing.expectEqual(@as(usize, 0), harness.reply_len);
    harness.feed("\x1b[3;4H\x1b_Ga=T,f=32,s=1,v=1,i=7,C=1;AQID/w==\x1b\\");
    try harness.expectImage();
}

test "PNG decoded pixels obey the screen quota" {
    const previous_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = previous_log_level;
    const harness = try Harness.create(3);
    defer harness.destroy();
    const command = try std.fmt.allocPrint(std.testing.allocator, "\x1b_Ga=T,f=100,i=7;{s}\x1b\\", .{encoded});
    defer std.testing.allocator.free(command);
    harness.feed(command);
    try std.testing.expectEqual(@as(usize, 0), harness.pipeline.terminal.screens.active.kitty_images.images.count());
    try std.testing.expect(harness.reply_len != 0);
}
