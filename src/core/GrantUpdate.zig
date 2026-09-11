const plugin = @import("plugin.zig");
const GrantUpdate = @This();

digest: plugin.Digest,
capabilities: plugin.CapabilitySet,
