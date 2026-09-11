const PendingTabSnapshot = @This();
const source_namespace = @import("response_queue.zig");
request_id: source_namespace.schema.RequestId,
location: source_namespace.schema.TabLocation,
