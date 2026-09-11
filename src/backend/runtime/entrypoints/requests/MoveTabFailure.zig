const FailureCodeType = @import("telar-core").FailureCode;
const Failure = @This();

code: FailureCodeType,
message: []const u8,
