//! The assistant text of one answered prompt, bounded by
//! `types.max_reply_bytes`.
const types = @import("types.zig");
const Reply = @This();

bytes: [types.max_reply_bytes]u8 = undefined,
len: u16 = 0,

/// The text written by the session.
///
/// ```zig
/// const text = reply.slice();
/// ```
pub fn slice(self: *const Reply) []const u8 {
    return self.bytes[0..self.len];
}
