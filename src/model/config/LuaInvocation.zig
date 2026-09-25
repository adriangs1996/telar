const EffectBatch = @import("EffectBatch.zig");
const effects_module = @import("effects.zig");
const Failure = @import("../input/Failure.zig");

pub const LuaInvocation = union(enum) {
    callback: EffectBatch,
    expression: effects_module.InputDecision,
    unavailable,
    failed: Failure,
};
