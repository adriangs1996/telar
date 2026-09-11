const EffectBatch = @This();
const source_namespace = @import("effects.zig");
const action = @import("../input/root.zig").action;
items: [source_namespace.max_callback_effects]action.Action = undefined,
len: u8 = 0,

pub fn slice(batch: *const EffectBatch) []const action.Action {
    return batch.items[0..batch.len];
}
