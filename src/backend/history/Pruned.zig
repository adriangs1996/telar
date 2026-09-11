const RequestIdType = @import("telar-core").RequestId;
const QueryOrigin = @import("QueryOrigin.zig");
const Pruned = @This();

request_id: RequestIdType,
origin: QueryOrigin,
removed: u64,
