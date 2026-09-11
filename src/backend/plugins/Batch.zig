const effects = @import("effects.zig");
const Batch = @This();

items: [effects.max_effects]effects.Effect = undefined,
len: u8 = 0,

pub fn slice(batch: *const Batch) []const effects.Effect {
    return batch.items[0..batch.len];
}
