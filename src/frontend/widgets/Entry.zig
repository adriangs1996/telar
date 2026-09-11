const Entry = @This();
const core = @import("telar-core");
command: []const u8,
cwd: []const u8,
id: u64,
pane_id: core.schema.PaneId,
started_at_ms: i64,
duration_ns: i64,
exit_code: ?i32,
status: core.schema.HistoryStatus,
author: core.schema.HistoryAuthor,
