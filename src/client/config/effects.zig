const InputKeys = @import("InputKeys.zig");
const InputPaste = @import("InputPaste.zig");

pub const max_callback_effects = 16;

pub const max_expression_keys = 16;

pub const max_expression_paste_bytes = 4096;

pub const InputDecision = union(enum) {
    consume,
    forward_binding: InputKeys,
    keys: InputKeys,
    paste: InputPaste,
};
