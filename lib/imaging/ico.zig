//! Bounded ICO directory decoding on the favicon worker. At most 64 entries
//! are inspected without allocation; only the chosen representation is decoded,
//! at no more than 256 x 256 RGBA pixels. PNG payloads reuse the PNG decoder.
const std = @import("std");
const IcoFrame = @import("IcoFrame.zig");
const DecodedImage = @import("DecodedImage.zig");

/// Decodes the representation closest to `cell`, preferring downsampling.
/// Example: `var image = try ico.decode(gpa, bytes, 32); defer image.deinit(gpa);`
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8, cell: u32) !DecodedImage {
    if (bytes.len < 6 or !std.mem.eql(u8, bytes[0..4], "\x00\x00\x01\x00")) {
        return error.NotIco;
    }

    const count: usize = std.mem.readInt(u16, bytes[4..6], .little);
    if (count == 0 or count > 64) {
        return error.UnsupportedIco;
    }

    const directory_end = 6 + count * 16;
    if (bytes.len < directory_end) {
        return error.InvalidIcoData;
    }

    var selected: ?IcoFrame = null;
    for (0..count) |index| {
        const entry = bytes[6 + index * 16 ..][0..16];
        const size: usize = std.mem.readInt(u32, entry[8..12], .little);
        const offset: usize = std.mem.readInt(u32, entry[12..16], .little);
        if (offset < directory_end or offset > bytes.len or size > bytes.len - offset) {
            return error.InvalidIcoData;
        }

        const frame = IcoFrame.init(entry, bytes[offset..][0..size]) catch |err| switch (err) {
            error.UnsupportedIco => continue,
            else => return err,
        };
        if (selected == null or frame.preferredTo(selected.?, cell)) {
            selected = frame;
        }
    }

    return try (selected orelse return error.UnsupportedIco).decode(gpa);
}

test "decodes the reported multi-resolution favicon at the requested display scale" {
    const bytes = @embedFile("testdata/telar.ico");
    for ([_]u32{ 16, 24, 32, 48, 64, 128 }, [_]u32{ 16, 32, 32, 48, 64, 64 }) |cell, expected| {
        var image = try decode(std.testing.allocator, bytes, cell);
        defer image.deinit(std.testing.allocator);
        try std.testing.expectEqual(expected, image.width);
        try std.testing.expectEqual(expected, image.height);
        var visible = false;
        for (0..image.pixels.len / 4) |index| {
            visible = visible or image.pixels[index * 4 + 3] != 0;
        }

        try std.testing.expect(visible);
    }
}

test "rejects truncated ICO directories and bitmaps and out-of-bounds offsets" {
    const original = @embedFile("testdata/telar.ico");
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const gpa = failing.allocator();
    for (0..original.len) |length| {
        if (decode(gpa, original[0..length], 32)) |image| {
            std.testing.allocator.free(image.pixels);
            return error.TruncatedIconAccepted;
        } else |err| {
            try std.testing.expect(err != error.OutOfMemory);
        }
    }

    var bytes = original.*;
    std.mem.writeInt(u32, bytes[18..22], std.math.maxInt(u32), .little);
    try std.testing.expectError(error.InvalidIcoData, decode(gpa, &bytes, 32));
    std.mem.writeInt(u32, bytes[18..22], 6, .little);
    try std.testing.expectError(error.InvalidIcoData, decode(gpa, &bytes, 32));
    bytes = original.*;
    std.mem.writeInt(u32, bytes[14..18], std.math.maxInt(u32), .little);
    try std.testing.expectError(error.InvalidIcoData, decode(gpa, &bytes, 32));
    bytes = original.*;
    std.mem.writeInt(u16, bytes[4..6], 65, .little);
    try std.testing.expectError(error.UnsupportedIco, decode(gpa, &bytes, 32));
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "PNG ICO entries reuse bounded PNG decoding and enforce directory dimensions" {
    const png = @import("png.zig");
    const gpa = std.testing.allocator;
    const samples = [_]u8{ 20, 40, 80, 128 } ** 4;
    const payload = try png.encodeForTest(gpa, .{ .header = .{ .width = 2, .height = 2, .color = .rgba } }, &samples);
    defer gpa.free(payload);
    var header = [_]u8{0} ** 22;
    header[2] = 1;
    header[4] = 1;
    header[6] = 2;
    header[7] = 2;
    std.mem.writeInt(u32, header[14..18], @intCast(payload.len), .little);
    header[18] = 22;
    const bytes = try std.mem.concat(gpa, u8, &.{ &header, payload });
    defer gpa.free(bytes);
    var image = try decode(gpa, bytes, 16);
    defer image.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &samples, image.pixels);

    bytes[6] = 3;
    try std.testing.expectError(error.InvalidIcoData, decode(gpa, bytes, 16));
    bytes[6] = 2;
    bytes[22 + 16] = 1;
    try std.testing.expectError(error.InvalidPngData, decode(gpa, bytes, 16));
}

test "ICO decoding releases ownership on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, expectAllocation, .{});
}

fn expectAllocation(gpa: std.mem.Allocator) !void {
    var image = try decode(gpa, @embedFile("testdata/telar.ico"), 32);
    defer image.deinit(gpa);
}
