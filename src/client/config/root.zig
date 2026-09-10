const std = @import("std");

pub const Diagnostic = struct {
    buffer: [512]u8 = undefined,
    len: usize = 0,

    pub fn message(diagnostic: *const Diagnostic) []const u8 {
        return diagnostic.buffer[0..diagnostic.len];
    }

    pub fn set(diagnostic: *Diagnostic, comptime format: []const u8, args: anytype) void {
        const rendered = std.fmt.bufPrint(&diagnostic.buffer, format, args) catch
            "configuration error";
        diagnostic.len = rendered.len;
    }
};

pub const CallbackContext = struct {
    sidebar_visible: bool,
    tab_count: u16,
    active_tab_index: u16,
    pane_count: u16,
    focused_pane_id: u64,
};

test {
    @import("std").testing.refAllDecls(@This());
}

pub const effects = @import("effects.zig");
pub const max_callback_effects = effects.max_callback_effects;
pub const max_expression_keys = effects.max_expression_keys;
pub const max_expression_paste_bytes = effects.max_expression_paste_bytes;
pub const EffectBatch = effects.EffectBatch;
pub const InputKeys = effects.InputKeys;
pub const InputPaste = effects.InputPaste;
pub const InputDecision = effects.InputDecision;
