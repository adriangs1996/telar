const PluginManifest = @import("telar-core").PluginManifest;
const DigestType = @import("telar-core").Digest;
const std = @import("std");
const Package = @This();

manifest: PluginManifest,
digest: DigestType,
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
