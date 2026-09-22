const core = @import("telar-core");
const Failure = @This();

request_id: core.RequestId,
code: core.FailureCode,
message: []const u8,
