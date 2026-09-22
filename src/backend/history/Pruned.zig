const core = @import("telar-core");
const QueryOrigin = @import("QueryOrigin.zig");
const Pruned = @This();

request_id: core.RequestId,
origin: QueryOrigin,
removed: u64,
