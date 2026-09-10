const keybind = @import("../input/root.zig").keybind;
const action = @import("../input/root.zig").action;

pub const max_callback_effects = 16;

pub const max_expression_keys = 16;

pub const max_expression_paste_bytes = 4096;

pub const EffectBatch = struct {
    items: [max_callback_effects]action.Action = undefined,
    len: u8 = 0,

    pub fn slice(batch: *const EffectBatch) []const action.Action {
        return batch.items[0..batch.len];
    }
};

pub const InputKeys = struct {
    items: [max_expression_keys]keybind.Key = undefined,
    len: u8 = 0,

    pub fn slice(keys: *const InputKeys) []const keybind.Key {
        return keys.items[0..keys.len];
    }
};

pub const InputPaste = struct {
    bytes: [max_expression_paste_bytes]u8 = undefined,
    len: u16 = 0,

    pub fn slice(paste: *const InputPaste) []const u8 {
        return paste.bytes[0..paste.len];
    }
};

pub const InputDecision = union(enum) {
    consume,
    forward_binding: InputKeys,
    keys: InputKeys,
    paste: InputPaste,
};
