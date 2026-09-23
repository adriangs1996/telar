const types = @import("types.zig");
const Response = @This();

purpose: types.Purpose,
status: types.Status,
text: [types.max_reply_bytes]u8 = undefined,
text_len: u16 = 0,

pub fn textSlice(self: *const Response) []const u8 {
    return self.text[0..self.text_len];
}
