const effects = @import("effects.zig");
const Key = @import("../input/Key.zig");
const InputKeys = @This();

items: [effects.max_expression_keys]Key = undefined,
len: u8 = 0,

pub fn slice(keys: *const InputKeys) []const Key {
    return keys.items[0..keys.len];
}
