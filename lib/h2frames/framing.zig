//! Incremental HTTP/2 frame boundaries; payloads are borrowed, never buffered.

const Reader = @import("Reader.zig");
const std = @import("std");

pub const header_bytes = 9;

test "fragmented headers, empty frames and payload offsets preserve frame boundaries" {
    const bytes = "\x00\x00\x03\x00\x01\x80\x00\x00\x07abc" ++ "\x00\x00\x00\x04\x01\x00\x00\x00\x00";
    const Receiver = struct {
        reader: *Reader,
        begins: usize = 0,
        ends: usize = 0,
        payload_bytes: usize = 0,

        pub fn beginFrame(receiver: *@This()) bool {
            if (receiver.begins == 0) {
                std.debug.assert(receiver.reader.stream_id == 7);
            }

            receiver.begins += 1;
            return true;
        }

        pub fn payload(receiver: *@This(), fragment: []const u8) bool {
            std.debug.assert(receiver.reader.payload_offset == receiver.payload_bytes);
            receiver.payload_bytes += fragment.len;
            return true;
        }

        pub fn finishFrame(receiver: *@This()) bool {
            receiver.ends += 1;
            return true;
        }
    };
    for (0..bytes.len + 1) |split| {
        var reader: Reader = .{};
        var receiver: Receiver = .{ .reader = &reader };
        try std.testing.expect(reader.feed(bytes[0..split], &receiver));
        try std.testing.expect(reader.feed(bytes[split..], &receiver));
        try std.testing.expectEqual(@as(usize, 2), receiver.begins);
        try std.testing.expectEqual(@as(usize, 2), receiver.ends);
        try std.testing.expectEqual(@as(usize, 3), receiver.payload_bytes);
        try std.testing.expectEqual(@as(u8, 0), reader.header_len);
    }
}
