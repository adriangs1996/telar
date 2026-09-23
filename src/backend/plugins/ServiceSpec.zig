const core = @import("telar-core");
const std = @import("std");
const Package = @import("Package.zig");
const Spec = @This();

package_index: u8,
plugin_id: u64,
digest: core.Digest,
generation: u64,
entry_storage: [std.fs.max_path_bytes]u8 = undefined,
entry_len: u16,
declared: core.CapabilitySet,
granted: core.CapabilitySet,

pub fn init(package_index: u8, generation: u64, package: Package) !Spec {
    if (package.entry.len > std.fs.max_path_bytes) {
        return error.PluginPathTooLong;
    }
    var spec: Spec = .{
        .package_index = package_index,
        .plugin_id = core.stableId(package.id),
        .digest = package.digest,
        .generation = generation,
        .entry_len = @intCast(package.entry.len),
        .declared = package.declared,
        .granted = package.granted,
    };
    @memcpy(spec.entry_storage[0..package.entry.len], package.entry);
    return spec;
}

pub fn entry(self: *const Spec) []const u8 {
    return self.entry_storage[0..self.entry_len];
}

pub fn allows(self: *const Spec, capability: core.Capability) bool {
    return self.declared.contains(capability) and self.granted.contains(capability);
}
