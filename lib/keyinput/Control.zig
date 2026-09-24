/// Whether a capture that saw a key lets routing continue to the keymap.
pub const Control = enum {
    continue_routing,
    stop,
};
