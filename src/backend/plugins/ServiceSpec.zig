const DigestType = @import("telar-core").Digest;
const std = @import("std");
const CapabilitySetType = @import("telar-core").CapabilitySet;
const Package = @import("Package.zig");
const stableId_module = @import("telar-core").stableId;
const CapabilityType = @import("telar-core").Capability;
const Spec = @This();

package_index: u8,
plugin_id: u64,
digest: DigestType,
generation: u64,
entry_storage: [std.fs.max_path_bytes]u8 = undefined,
entry_len: u16,
declared: CapabilitySetType,
granted: CapabilitySetType,

pub fn init(package_index: u8, generation: u64, package: Package) !Spec {
    if (package.entry.len > std.fs.max_path_bytes) {
        return error.PluginPathTooLong;
    }
    var spec: Spec = .{
        .package_index = package_index,
        .plugin_id = stableId_module(package.id),
        .digest = package.digest,
        .generation = generation,
        .entry_len = @intCast(package.entry.len),
        .declared = package.declared,
        .granted = package.granted,
    };
    @memcpy(spec.entry_storage[0..package.entry.len], package.entry);
    return spec;
}

pub fn entry(spec: *const Spec) []const u8 {
    return spec.entry_storage[0..spec.entry_len];
}

pub fn allows(spec: *const Spec, capability: CapabilityType) bool {
    return spec.declared.contains(capability) and spec.granted.contains(capability);
}
