const keybind = @import("../input/root.zig").keybind;
const action = @import("../input/root.zig").action;

pub const max_callback_effects = 16;

pub const max_expression_keys = 16;

pub const max_expression_paste_bytes = 4096;

pub const EffectBatch = @import("EffectBatch.zig");

pub const InputKeys = @import("InputKeys.zig");

pub const InputPaste = @import("InputPaste.zig");

pub const InputDecision = union(enum) {
    consume,
    forward_binding: InputKeys,
    keys: InputKeys,
    paste: InputPaste,
};
