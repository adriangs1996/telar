const Package = @This();
const source_namespace = @import("root.zig");
const std = @import("std");
manifest: source_namespace.plugin.Manifest,
digest: source_namespace.plugin.Digest,
root_bytes: [std.fs.max_path_bytes]u8 = undefined,
root_len: u16,
entry_bytes: [std.fs.max_path_bytes]u8 = undefined,
entry_len: u16,

pub fn root(package: *const Package) []const u8 {
    return package.root_bytes[0..package.root_len];
}

pub fn entryPath(package: *const Package) []const u8 {
    return package.entry_bytes[0..package.entry_len];
}
