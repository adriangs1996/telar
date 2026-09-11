const RequestFailed = @This();
const source_namespace = @import("runtime.zig");
/// Zero identifies a connection-level error rather than a request.
request_id: source_namespace.RequestId,
code: source_namespace.FailureCode,
message: []const u8,
