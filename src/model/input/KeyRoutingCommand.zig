const keyinput = @import("keyinput");
const Key = keyinput.Key;

pub const KeyRoutingCommand = union(enum) {
    bytes: []const u8,
    key: Key,
};
