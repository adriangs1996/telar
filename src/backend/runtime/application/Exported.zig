const ClientIdentityType = @import("telar-core").ClientIdentity;
const Exported = @This();

identity: ClientIdentityType,
last_used: u64,
payload: []const u8,
