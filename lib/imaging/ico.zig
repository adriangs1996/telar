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
