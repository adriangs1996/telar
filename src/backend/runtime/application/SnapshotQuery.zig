const core = @import("telar-core");
const Sources = @import("Sources.zig");
const SnapshotQuery = @This();

identity: core.ClientIdentity,
sources: Sources,
