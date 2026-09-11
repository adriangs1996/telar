/// Reply for requests that succeed without producing data.
const RequestCompleted = @This();
const source_namespace = @import("runtime.zig");
request_id: source_namespace.RequestId,
