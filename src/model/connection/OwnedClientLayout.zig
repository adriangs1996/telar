const core = @import("telar-core");
const std = @import("std");
const OwnedClientLayout = @This();

// SAFETY: Outbox.claimClientLayout encodes into this buffer before publishing len and used; slice exposes only the encoded prefix.
bytes: [core.max_client_layout_wire_bytes]u8 = undefined,
len: u16 = 0,
used: bool = false,

pub fn slice(self: *const OwnedClientLayout) []const u8 {
    std.debug.assert(self.used and self.len != 0);
    return self.bytes[0..self.len];
}
