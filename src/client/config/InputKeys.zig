const effects = @import("effects.zig");
const KeyType = @import("../input/Key.zig");
const InputKeys = @This();

items: [effects.max_expression_keys]KeyType = undefined,
len: u8 = 0,

pub fn slice(keys: *const InputKeys) []const KeyType {
    return keys.items[0..keys.len];
}
