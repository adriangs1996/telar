//! A foreground process that may be the editor to reuse, and the terminal
//! it draws on once discovery reads it.
const Candidate = @This();

process_group: u32,
tty_bytes: [128]u8 = undefined,
tty_len: u8 = 0,

pub fn tty(self: *const Candidate) []const u8 {
    return self.tty_bytes[0..self.tty_len];
}
