const Batch = @This();
const source_namespace = @import("effects.zig");
items: [source_namespace.max_effects]source_namespace.Effect = undefined,
len: u8 = 0,

pub fn slice(batch: *const Batch) []const source_namespace.Effect {
    return batch.items[0..batch.len];
}
