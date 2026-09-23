const EffectBatch = @import("../config/EffectBatch.zig");
const effects_module = @import("../config/effects.zig");
const Failure = @import("../input/Failure.zig");

pub const LuaInvocation = union(enum) {
    callback: EffectBatch,
    expression: effects_module.InputDecision,
    unavailable,
    failed: Failure,
};
