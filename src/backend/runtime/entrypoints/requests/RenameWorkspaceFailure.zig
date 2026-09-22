const core = @import("telar-core");
const Failure = @This();

code: core.FailureCode,
message: []const u8,
