const core = @import("telar-core");

pub const max_callback_effects = 16;
pub const callback_effects_limit = core.Limit.declare("config.max_callback_effects", "effects", max_callback_effects);

pub const max_expression_keys = 16;

pub const max_expression_paste_bytes = 4096;

pub const InputDecision = @import("InputDecision.zig").InputDecision;
