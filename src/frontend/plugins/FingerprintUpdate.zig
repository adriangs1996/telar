const FingerprintUpdate = @This();
const std = @import("std");
hasher: *std.hash.Wyhash,
root: []const u8,
