//! The label of a `mark` line, owned.
const InputLabel = @This();

/// The longest label, in bytes.
pub const max_bytes = 32;

bytes: [max_bytes]u8 = undefined,
len: u8 = 0,

pub fn slice(self: *const InputLabel) []const u8 {
    return self.bytes[0..self.len];
}
