const ActionName = @This();
const source_namespace = @import("plugin.zig");
bytes: [source_namespace.max_action_bytes]u8 = undefined,
len: u8,

pub fn slice(value: *const ActionName) []const u8 {
    return value.bytes[0..value.len];
}
