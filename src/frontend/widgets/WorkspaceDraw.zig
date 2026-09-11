const WorkspaceListSnapshot = @import("telar-client").WorkspaceListSnapshot;
const RectType = @import("telar-core").Rect;
const WorkspaceDraw = @This();

snapshot: *const WorkspaceListSnapshot,
index: usize,
active_index: ?usize,
active_name: []const u8,
area: RectType,
