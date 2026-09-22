const core = @import("telar-core");
const PendingFailure = @This();

request_id: core.RequestId,
code: core.FailureCode,
message: []const u8,
