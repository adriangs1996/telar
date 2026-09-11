const id_module = @import("id.zig");
const types = @import("types.zig");
const HistoryEntry = @This();

id: u64,
pane_id: id_module.PaneId,
started_at_ms: i64,
duration_ns: i64,
exit_code: ?i32,
status: types.HistoryStatus,
author: types.HistoryAuthor = .human,
origin: types.HistoryOrigin = .pane,
provider: []const u8 = "",
command: []const u8,
cwd: []const u8,
workspace_path: []const u8,
command_truncated: bool = false,
