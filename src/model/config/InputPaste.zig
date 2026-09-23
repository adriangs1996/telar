const effects = @import("effects.zig");
const InputPaste = @This();

bytes: [effects.max_expression_paste_bytes]u8 = undefined,
len: u16 = 0,

pub fn slice(self: *const InputPaste) []const u8 {
    return self.bytes[0..self.len];
}
