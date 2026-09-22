const core = @import("telar-core");
const QueryOrigin = @import("QueryOrigin.zig");
const Delete = @This();

request_id: core.RequestId,
origin: QueryOrigin,
id: u64,
