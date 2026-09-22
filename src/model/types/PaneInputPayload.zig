const Key = @import("../input/Key.zig");

pub const PaneInputPayload = union(enum) {
    bytes: []const u8,
    key: Key,
};
