const PendingWorkspaceSnapshot = @This();
const source_namespace = @import("response_queue.zig");
request_id: source_namespace.schema.RequestId,
workspace: source_namespace.schema.WorkspaceLocation,
