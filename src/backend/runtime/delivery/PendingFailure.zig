const RequestIdType = @import("telar-core").RequestId;
const FailureCodeType = @import("telar-core").FailureCode;
const PendingFailure = @This();

request_id: RequestIdType,
code: FailureCodeType,
message: []const u8,
