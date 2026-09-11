const Entry = @This();
const source_namespace = @import("history_palette.zig");
id: u64 = 0,
status: source_namespace.schema.HistoryStatus = .completed,
author: source_namespace.schema.HistoryAuthor = .human,
exit_code: ?i32 = null,
pane_id: source_namespace.schema.PaneId = .invalid,
started_at_ms: i64 = 0,
duration_ns: i64 = 0,
full_offset: u32 = 0,
full_len: u32 = 0,
command_complete: bool = false,
captured_truncated: bool = false,
command: [source_namespace.max_command_bytes]u8 = undefined,
command_len: u16 = 0,
cwd: [source_namespace.max_entry_cwd_bytes]u8 = undefined,
cwd_len: u16 = 0,

pub fn commandSlice(entry: *const Entry) []const u8 {
    return entry.command[0..entry.command_len];
}

pub fn cwdSlice(entry: *const Entry) []const u8 {
    return entry.cwd[0..entry.cwd_len];
}
