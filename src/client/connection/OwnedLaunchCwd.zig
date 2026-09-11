const OwnedLaunchCwd = @This();
const source_namespace = @import("outbox_support.zig");
const std = @import("std");
bytes: [source_namespace.schema.max_cwd_bytes]u8 = undefined,
len: u16 = 0,
used: bool = false,

pub fn slice(cwd: *const OwnedLaunchCwd) []const u8 {
    std.debug.assert(cwd.used and cwd.len != 0);
    return cwd.bytes[0..cwd.len];
}
