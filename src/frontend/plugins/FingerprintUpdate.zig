const std = @import("std");
const FingerprintUpdate = @This();

hasher: *std.hash.Wyhash,
root: []const u8,
