const plugin = @import("plugin.zig");
const PluginIdentity = @import("PluginIdentity.zig");
const std = @import("std");
const Grant = @This();

plugin_hash: u64,
digest: plugin.Digest,
capabilities: plugin.CapabilitySet,

/// Checks that this grant matches an exact package before testing one capability.
///
/// ```zig
/// if (grant.allows(.{ .id = manifest.id(), .digest = digest }, .history_read)) readHistory();
/// ```
pub fn allows(self: Grant, identity: PluginIdentity, capability: plugin.Capability) bool {
    return self.plugin_hash == plugin.stableId(identity.id) and
        std.mem.eql(u8, &self.digest, &identity.digest) and
        self.capabilities.contains(capability);
}
