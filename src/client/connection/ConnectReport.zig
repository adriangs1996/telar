//! What a failed connection attempt said: SSH's error output or the
//! runtime's refusal, bounded like the link failure the chrome shows. The
//! connection worker writes it; the client reads it after the completion.
const data = @import("model");
const std = @import("std");
const ConnectReport = @This();

bytes: [data.RuntimeLink.max_failure_bytes]u8 = undefined,
len: usize = 0,

pub fn text(self: *const ConnectReport) []const u8 {
    return self.bytes[0..self.len];
}
