const Reader = @This();
const source_namespace = @import("framing.zig");
header: [source_namespace.header_bytes]u8 = undefined,
header_len: u8 = 0,
payload_len: usize = 0,
payload_left: usize = 0,
payload_offset: usize = 0,
frame_type: u8 = 0,
flags: u8 = 0,
stream_id: u32 = 0,

/// Calls beginFrame, payload and finishFrame without owning their policy.
/// Returning false from a receiver stops consumption immediately.
/// Example: `if (!reader.feed(bytes, &receiver)) closeConnection();`.
pub fn feed(reader: *Reader, input: []const u8, receiver: anytype) bool {
    var offset: usize = 0;
    while (offset < input.len) {
        if (reader.header_len < source_namespace.header_bytes) {
            const take = @min(source_namespace.header_bytes - reader.header_len, input.len - offset);
            @memcpy(reader.header[reader.header_len..][0..take], input[offset..][0..take]);
            reader.header_len += @intCast(take);
            offset += take;
            if (reader.header_len != source_namespace.header_bytes) {
                continue;
            }

            reader.decodeHeader();
            if (!receiver.beginFrame()) {
                return false;
            }

            if (reader.payload_left == 0) {
                if (!receiver.finishFrame()) {
                    return false;
                }

                reader.finish();
            }

            continue;
        }

        const take = @min(reader.payload_left, input.len - offset);
        if (!receiver.payload(input[offset..][0..take])) {
            return false;
        }

        reader.payload_offset += take;
        reader.payload_left -= take;
        offset += take;
        if (reader.payload_left == 0) {
            if (!receiver.finishFrame()) {
                return false;
            }

            reader.finish();
        }
    }

    return true;
}

fn decodeHeader(reader: *Reader) void {
    reader.payload_len = (@as(usize, reader.header[0]) << 16) | (@as(usize, reader.header[1]) << 8) | reader.header[2];
    reader.payload_left = reader.payload_len;
    reader.payload_offset = 0;
    reader.frame_type = reader.header[3];
    reader.flags = reader.header[4];
    reader.stream_id = (@as(u32, reader.header[5] & 0x7f) << 24) | (@as(u32, reader.header[6]) << 16) | (@as(u32, reader.header[7]) << 8) | reader.header[8];
}

fn finish(reader: *Reader) void {
    reader.header_len = 0;
    reader.payload_len = 0;
    reader.payload_left = 0;
    reader.payload_offset = 0;
}
