const max_cwd_bytes_module = @import("telar-core").max_cwd_bytes;
const std = @import("std");
const OwnedLaunchCwd = @This();

bytes: [max_cwd_bytes_module]u8 = undefined,
len: u16 = 0,
used: bool = false,

pub fn slice(cwd: *const OwnedLaunchCwd) []const u8 {
    std.debug.assert(cwd.used and cwd.len != 0);
    return cwd.bytes[0..cwd.len];
}
