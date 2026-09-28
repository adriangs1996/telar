//! Characters a `text` line types, owned.
const InputText = @This();

/// The most text one line carries, in bytes.
pub const max_bytes = 1024;

bytes: [max_bytes]u8 = undefined,
len: u16 = 0,

pub fn slice(self: *const InputText) []const u8 {
    return self.bytes[0..self.len];
}
