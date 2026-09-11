const WorkspaceListSnapshot = @import("telar-client").WorkspaceListSnapshot;
const WorkspaceNames = @This();

snapshot: *const WorkspaceListSnapshot,
active_index: ?usize,
active_name: []const u8,
