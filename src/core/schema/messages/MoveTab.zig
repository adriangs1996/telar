const MoveTab = @This();
const source_namespace = @import("tab.zig");
request_id: source_namespace.RequestId,
location: source_namespace.TabLocation,
direction: source_namespace.TabMoveDirection,
