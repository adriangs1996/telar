const Key = @import("../input/Key.zig");

pub const KeyRoutingCommand = union(enum) {
    bytes: []const u8,
    key: Key,
};
