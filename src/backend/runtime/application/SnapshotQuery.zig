const ClientIdentityType = @import("telar-core").ClientIdentity;
const Sources = @import("Sources.zig");
const SnapshotQuery = @This();

identity: ClientIdentityType,
sources: Sources,
