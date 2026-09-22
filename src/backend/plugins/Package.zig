const core = @import("telar-core");
const Package = @This();

id: []const u8,
entry: []const u8,
digest: core.Digest,
declared: core.CapabilitySet,
granted: core.CapabilitySet,
