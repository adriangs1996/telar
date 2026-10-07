/// Bounds the window applies while it routes native input.
pub const InputLimit = enum(u8) {
    minimum_outbox_slots = 4,
    scroll_lines_per_event = 32,
};
