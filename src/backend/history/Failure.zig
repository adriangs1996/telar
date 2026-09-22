const core = @import("telar-core");
const QueryOrigin = @import("QueryOrigin.zig");
const Failure = @This();

request_id: core.RequestId,
origin: QueryOrigin,
message: []const u8,
