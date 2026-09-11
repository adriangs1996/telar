const InputKeys = @This();
const source_namespace = @import("effects.zig");
const keybind = @import("../input/root.zig").keybind;
items: [source_namespace.max_expression_keys]keybind.Key = undefined,
len: u8 = 0,

pub fn slice(keys: *const InputKeys) []const keybind.Key {
    return keys.items[0..keys.len];
}
