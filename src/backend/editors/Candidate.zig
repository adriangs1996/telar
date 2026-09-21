const PaneKey = @import("../pane/PaneKey.zig");

pane: PaneKey,
process_group: u32,
tty_bytes: [128]u8 = undefined,
tty_len: u8 = 0,

pub fn tty(self: *const @This()) []const u8 {
    return self.tty_bytes[0..self.tty_len];
}
