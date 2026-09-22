const core = @import("telar-core");
const Exported = @This();

identity: core.ClientIdentity,
last_used: u64,
payload: []const u8,
