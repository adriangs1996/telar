const DigestType = @import("telar-core").Digest;
const CapabilitySetType = @import("telar-core").CapabilitySet;
const Package = @This();

id: []const u8,
entry: []const u8,
digest: DigestType,
declared: CapabilitySetType,
granted: CapabilitySetType,
