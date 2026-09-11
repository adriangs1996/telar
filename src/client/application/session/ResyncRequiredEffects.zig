const Effects = @This();
const source_namespace = @import("resync_required.zig");
context: *anyopaque,
forget_workspace: *const fn (*anyopaque, source_namespace.schema.WorkspaceLocation) void,
request_snapshot: *const fn (*anyopaque, source_namespace.schema.WorkspaceLocation) anyerror!void,
request_handoff: *const fn (*anyopaque, source_namespace.schema.WorkspaceId) anyerror!void,
