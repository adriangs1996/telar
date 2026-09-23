const core = @import("telar-core");
const std = @import("std");
const Package = @This();

manifest: core.PluginManifest,
digest: core.Digest,
root_bytes: [std.fs.max_path_bytes]u8 = undefined,
root_len: u16,

pub fn root(self: *const Package) []const u8 {
    return self.root_bytes[0..self.root_len];
}
