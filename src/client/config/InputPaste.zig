const effects = @import("effects.zig");
const InputPaste = @This();

bytes: [effects.max_expression_paste_bytes]u8 = undefined,
len: u16 = 0,

pub fn slice(paste: *const InputPaste) []const u8 {
    return paste.bytes[0..paste.len];
}
