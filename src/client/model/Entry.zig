const HistoryStatusType = @import("telar-core").HistoryStatus;
const HistoryAuthorType = @import("telar-core").HistoryAuthor;
const PaneIdType = @import("telar-core").PaneId;
const history_palette = @import("history_palette.zig");
const Entry = @This();

id: u64 = 0,
status: HistoryStatusType = .completed,
author: HistoryAuthorType = .human,
exit_code: ?i32 = null,
pane_id: PaneIdType = .invalid,
started_at_ms: i64 = 0,
duration_ns: i64 = 0,
full_offset: u32 = 0,
full_len: u32 = 0,
command_complete: bool = false,
captured_truncated: bool = false,
command: [history_palette.max_command_bytes]u8 = undefined,
command_len: u16 = 0,
cwd: [history_palette.max_entry_cwd_bytes]u8 = undefined,
cwd_len: u16 = 0,

pub fn commandSlice(entry: *const Entry) []const u8 {
    return entry.command[0..entry.command_len];
}

pub fn cwdSlice(entry: *const Entry) []const u8 {
    return entry.cwd[0..entry.cwd_len];
}
