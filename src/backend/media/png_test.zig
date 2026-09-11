const std = @import("std");
const vt = @import("ghostty-vt");
const core = @import("telar-core");
const media = @import("root.zig");

pub const size: core.schema.TerminalSize = .{ .cols = 10, .rows = 5, .cell_width_px = 10, .cell_height_px = 20 };
const fixture = @embedFile("testdata/rgba.png");
const encoded = &encoded_storage;
const encoded_storage = encoded: {
    var buffer: [std.base64.standard.Encoder.calcSize(fixture.len)]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&buffer, fixture);
    break :encoded buffer;
};

const Harness = @import("Harness.zig");

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
