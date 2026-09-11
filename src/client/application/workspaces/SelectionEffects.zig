const SelectionEffects = @This();
const source_namespace = @import("workspace_handoff.zig");
context: *anyopaque,
request: *const fn (*anyopaque, source_namespace.schema.WorkspaceId) anyerror!void,
