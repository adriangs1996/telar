const RequestIdType = @import("telar-core").RequestId;
const QueryOrigin = @import("QueryOrigin.zig");
const Delete = @This();

request_id: RequestIdType,
origin: QueryOrigin,
id: u64,
