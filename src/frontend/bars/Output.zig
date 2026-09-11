const Output = @This();
const source_namespace = @import("command.zig");
bytes: [source_namespace.max_output_bytes]u8 = @splat(0),
len: u16 = 0,

pub fn slice(output: *const Output) []const u8 {
    return output.bytes[0..output.len];
}
