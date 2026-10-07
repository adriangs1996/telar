const effects = @import("effects.zig");
const action = @import("../input/action.zig");
const EffectBatch = @This();

// SAFETY: Effect producers fill the batch before publishing len; slice and protocol encoding read only that prefix.
items: [effects.max_callback_effects]action.Action = undefined,
len: u8 = 0,

pub fn slice(self: *const EffectBatch) []const action.Action {
    return self.items[0..self.len];
}
