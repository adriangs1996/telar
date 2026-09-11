const effects = @import("effects.zig");
const action = @import("../input/action.zig");
const EffectBatch = @This();

items: [effects.max_callback_effects]action.Action = undefined,
len: u8 = 0,

pub fn slice(batch: *const EffectBatch) []const action.Action {
    return batch.items[0..batch.len];
}
