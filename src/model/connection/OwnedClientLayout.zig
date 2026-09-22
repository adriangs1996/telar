const core = @import("telar-core");
const std = @import("std");
const OwnedClientLayout = @This();

bytes: [core.max_client_layout_wire_bytes]u8 = undefined,
len: u16 = 0,
used: bool = false,

pub fn slice(layout: *const OwnedClientLayout) []const u8 {
    std.debug.assert(layout.used and layout.len != 0);
    return layout.bytes[0..layout.len];
}
