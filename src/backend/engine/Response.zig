const types = @import("types.zig");
const Response = @This();

purpose: types.Purpose,
status: types.Status,
text: [types.max_reply_bytes]u8 = undefined,
text_len: u16 = 0,

pub fn textSlice(response: *const Response) []const u8 {
    return response.text[0..response.text_len];
}
