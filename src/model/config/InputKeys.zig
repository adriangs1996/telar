const keyinput = @import("keyinput");
const effects = @import("effects.zig");
const Key = keyinput.Key;
const InputKeys = @This();

// SAFETY: Input decision parsing copies or parses every key before setting len; slice exposes only those initialized keys.
items: [effects.max_expression_keys]Key = undefined,
len: u8 = 0,

pub fn slice(self: *const InputKeys) []const Key {
    return self.items[0..self.len];
}
