const HistoryEntry = @This();
const id_module = @import("id.zig");
const source_namespace = @import("types.zig");
id: u64,
pane_id: id_module.PaneId,
started_at_ms: i64,
duration_ns: i64,
exit_code: ?i32,
status: source_namespace.HistoryStatus,
author: source_namespace.HistoryAuthor = .human,
origin: source_namespace.HistoryOrigin = .pane,
provider: []const u8 = "",
command: []const u8,
cwd: []const u8,
workspace_path: []const u8,
command_truncated: bool = false,
