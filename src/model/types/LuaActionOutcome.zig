const effects_module = @import("../config/effects.zig");

pub const LuaActionOutcome = union(enum) {
    applied,
    exit,
    input: effects_module.InputDecision,
    unavailable,
    invocation_failed: anyerror,
    validation_failed: anyerror,
};
