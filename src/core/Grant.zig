const Grant = @This();
const source_namespace = @import("plugin.zig");
const PluginIdentity = @import("PluginIdentity.zig");
const std = @import("std");
plugin_hash: u64,
digest: source_namespace.Digest,
capabilities: source_namespace.CapabilitySet,

/// Checks that this grant matches an exact package before testing one capability.
///
/// ```zig
/// if (grant.allows(.{ .id = manifest.id(), .digest = digest }, .history_read)) readHistory();
/// ```
pub fn allows(grant: Grant, identity: PluginIdentity, capability: source_namespace.Capability) bool {
    return grant.plugin_hash == source_namespace.stableId(identity.id) and
        std.mem.eql(u8, &grant.digest, &identity.digest) and
        grant.capabilities.contains(capability);
}
