const client = @import("telar-client");
const WorkspaceNames = @This();

snapshot: *const client.WorkspaceListSnapshot,
active_index: ?usize,
active_name: []const u8,
