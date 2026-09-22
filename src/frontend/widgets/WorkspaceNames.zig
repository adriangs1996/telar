const data = @import("model");
const client = @import("telar-client");
const WorkspaceNames = @This();

snapshot: *const data.WorkspaceListSnapshot,
active_index: ?usize,
active_name: []const u8,
