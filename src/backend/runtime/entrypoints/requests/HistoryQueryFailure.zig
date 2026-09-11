const Failure = @This();
const source_namespace = @import("history_query.zig");
request_id: source_namespace.schema.RequestId,
code: source_namespace.schema.FailureCode,
message: []const u8,
