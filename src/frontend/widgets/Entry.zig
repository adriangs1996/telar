const PaneIdType = @import("telar-core").PaneId;
const HistoryStatusType = @import("telar-core").HistoryStatus;
const HistoryAuthorType = @import("telar-core").HistoryAuthor;
const Entry = @This();

command: []const u8,
cwd: []const u8,
id: u64,
pane_id: PaneIdType,
started_at_ms: i64,
duration_ns: i64,
exit_code: ?i32,
status: HistoryStatusType,
author: HistoryAuthorType,
