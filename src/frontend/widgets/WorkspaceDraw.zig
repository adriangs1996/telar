const client = @import("telar-client");
const core = @import("telar-core");
const WorkspaceDraw = @This();

snapshot: *const client.WorkspaceListSnapshot,
index: usize,
active_index: ?usize,
active_name: []const u8,
area: core.Rect,
