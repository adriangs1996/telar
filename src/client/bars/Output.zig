const max_text_bytes = @import("model.zig").max_text_bytes;
const Output = @This();

bytes: [max_text_bytes]u8 = @splat(0),
len: u16 = 0,

pub fn slice(output: *const Output) []const u8 {
    return output.bytes[0..output.len];
}
