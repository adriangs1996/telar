const Package = @This();
const core = @import("telar-core");
id: []const u8,
entry: []const u8,
digest: core.plugin.Digest,
declared: core.plugin.CapabilitySet,
granted: core.plugin.CapabilitySet,
