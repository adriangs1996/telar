const framing = @import("framing.zig");
const Reader = @This();

header: [framing.header_bytes]u8 = undefined,
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
pub fn feed(self: *Reader, input: []const u8, receiver: anytype) bool {
    var offset: usize = 0;
    while (offset < input.len) {
        if (self.header_len < framing.header_bytes) {
            const take = @min(framing.header_bytes - self.header_len, input.len - offset);
            @memcpy(self.header[self.header_len..][0..take], input[offset..][0..take]);
            self.header_len += @intCast(take);
            offset += take;
            if (self.header_len != framing.header_bytes) {
                continue;
            }

            self.decodeHeader();
            if (!receiver.beginFrame()) {
                return false;
            }

            if (self.payload_left == 0) {
                if (!receiver.finishFrame()) {
                    return false;
                }

                self.finish();
            }

            continue;
        }

        const take = @min(self.payload_left, input.len - offset);
        if (!receiver.payload(input[offset..][0..take])) {
            return false;
        }

        self.payload_offset += take;
        self.payload_left -= take;
        offset += take;
        if (self.payload_left == 0) {
            if (!receiver.finishFrame()) {
                return false;
            }

            self.finish();
        }
    }

    return true;
}

fn decodeHeader(self: *Reader) void {
    self.payload_len = (@as(usize, self.header[0]) << 16) | (@as(usize, self.header[1]) << 8) | self.header[2];
    self.payload_left = self.payload_len;
    self.payload_offset = 0;
    self.frame_type = self.header[3];
    self.flags = self.header[4];
    self.stream_id = (@as(u32, self.header[5] & 0x7f) << 24) | (@as(u32, self.header[6]) << 16) | (@as(u32, self.header[7]) << 8) | self.header[8];
}

fn finish(self: *Reader) void {
    self.header_len = 0;
    self.payload_len = 0;
    self.payload_left = 0;
    self.payload_offset = 0;
}
