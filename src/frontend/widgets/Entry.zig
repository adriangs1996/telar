const core = @import("telar-core");
const Entry = @This();

command: []const u8,
cwd: []const u8,
id: u64,
pane_id: core.PaneId,
started_at_ms: i64,
duration_ns: i64,
exit_code: ?i32,
status: core.HistoryStatus,
author: core.HistoryAuthor,
