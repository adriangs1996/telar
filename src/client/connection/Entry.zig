const Entry = @This();
const source_namespace = @import("requests.zig");
request_id: source_namespace.schema.RequestId,
continuation: source_namespace.Continuation,
