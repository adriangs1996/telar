const effects = @import("effects.zig");
const action = @import("../input/action.zig");
const EffectBatch = @This();

items: [effects.max_callback_effects]action.Action = undefined,
len: u8 = 0,

pub fn slice(self: *const EffectBatch) []const action.Action {
    return self.items[0..self.len];
}
