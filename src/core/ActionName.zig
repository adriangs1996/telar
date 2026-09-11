const plugin = @import("plugin.zig");
const ActionName = @This();

bytes: [plugin.max_action_bytes]u8 = undefined,
len: u8,

pub fn slice(value: *const ActionName) []const u8 {
    return value.bytes[0..value.len];
}
