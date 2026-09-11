const PendingFailure = @This();
const source_namespace = @import("response_queue.zig");
request_id: source_namespace.schema.RequestId,
code: source_namespace.schema.FailureCode,
message: []const u8,
