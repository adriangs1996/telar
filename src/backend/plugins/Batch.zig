const effects = @import("effects.zig");
const Batch = @This();

items: [effects.max_effects]effects.Effect = undefined,
len: u8 = 0,

pub fn slice(self: *const Batch) []const effects.Effect {
    return self.items[0..self.len];
}
