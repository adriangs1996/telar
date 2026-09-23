const plugin = @import("plugin.zig");
const ActionName = @This();

bytes: [plugin.max_action_bytes]u8 = undefined,
len: u8,

pub fn slice(self: *const ActionName) []const u8 {
    return self.bytes[0..self.len];
}
