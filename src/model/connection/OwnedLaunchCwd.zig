const core = @import("telar-core");
const std = @import("std");
const OwnedLaunchCwd = @This();

// SAFETY: Outbox.claimLaunchCwd copies the path before setting len and used; slice requires an occupied slot and reads only len bytes.
bytes: [core.max_cwd_bytes]u8 = undefined,
len: u16 = 0,
used: bool = false,

pub fn slice(self: *const OwnedLaunchCwd) []const u8 {
    std.debug.assert(self.used and self.len != 0);
    return self.bytes[0..self.len];
}
