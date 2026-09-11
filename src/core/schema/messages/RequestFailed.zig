const id = @import("../id.zig");
const types = @import("../types.zig");
const RequestFailed = @This();

/// Zero identifies a connection-level error rather than a request.
request_id: id.RequestId,
code: types.FailureCode,
message: []const u8,
