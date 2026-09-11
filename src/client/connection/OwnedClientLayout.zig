const OwnedClientLayout = @This();
const source_namespace = @import("outbox_support.zig");
const std = @import("std");
bytes: [source_namespace.schema.max_client_layout_wire_bytes]u8 = undefined,
len: u16 = 0,
used: bool = false,

pub fn slice(layout: *const OwnedClientLayout) []const u8 {
    std.debug.assert(layout.used and layout.len != 0);
    return layout.bytes[0..layout.len];
}
