const WorkspaceDraw = @This();
const workspace_list = @import("telar-client").workspace.workspace_list;
const ui = @import("../ui/root.zig");
snapshot: *const workspace_list.Snapshot,
index: usize,
active_index: ?usize,
active_name: []const u8,
area: ui.Rect,
