const Failure = @This();
const source_namespace = @import("model.zig");
const QueryOrigin = @import("QueryOrigin.zig");
request_id: source_namespace.schema.RequestId,
origin: QueryOrigin,
message: []const u8,
