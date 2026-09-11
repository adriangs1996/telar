const Response = @This();
const source_namespace = @import("types.zig");
purpose: source_namespace.Purpose,
status: source_namespace.Status,
text: [source_namespace.max_reply_bytes]u8 = undefined,
text_len: u16 = 0,

pub fn textSlice(response: *const Response) []const u8 {
    return response.text[0..response.text_len];
}
