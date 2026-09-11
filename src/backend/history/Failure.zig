const RequestIdType = @import("telar-core").RequestId;
const QueryOrigin = @import("QueryOrigin.zig");
const Failure = @This();

request_id: RequestIdType,
origin: QueryOrigin,
message: []const u8,
