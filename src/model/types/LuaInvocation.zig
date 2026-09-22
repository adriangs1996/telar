const EffectBatchType = @import("../config/EffectBatch.zig");
const effects_module = @import("../config/effects.zig");
const Failure = @import("../application/input/Failure.zig");

pub const LuaInvocation = union(enum) {
    callback: EffectBatchType,
    expression: effects_module.InputDecision,
    unavailable,
    failed: Failure,
};
