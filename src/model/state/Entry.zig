const core = @import("telar-core");
const history_palette = @import("history_palette.zig");
const Entry = @This();

id: u64 = 0,
status: core.HistoryStatus = .completed,
author: core.HistoryAuthor = .human,
origin: core.HistoryOrigin = .pane,
exit_code: ?i32 = null,
pane_id: core.PaneId = .invalid,
started_at_ms: i64 = 0,
duration_ns: i64 = 0,
full_offset: u32 = 0,
full_len: u32 = 0,
command_complete: bool = false,
captured_truncated: bool = false,
// SAFETY: HistoryPaletteState copies the bounded command before publishing command_len; commandSlice exposes only that prefix.
command: [history_palette.max_command_bytes]u8 = undefined,
command_len: u16 = 0,
// SAFETY: HistoryPaletteState copies the bounded directory before publishing cwd_len; cwdSlice exposes only that prefix.
cwd: [history_palette.max_entry_cwd_bytes]u8 = undefined,
cwd_len: u16 = 0,
/// Manifest name of the agent that submitted the command; empty for people.
// SAFETY: HistoryPaletteState copies the bounded provider before publishing provider_len; providerSlice exposes only that prefix.
provider: [core.max_history_provider_bytes]u8 = undefined,
provider_len: u8 = 0,

pub fn commandSlice(self: *const Entry) []const u8 {
    return self.command[0..self.command_len];
}

pub fn cwdSlice(self: *const Entry) []const u8 {
    return self.cwd[0..self.cwd_len];
}

pub fn providerSlice(self: *const Entry) []const u8 {
    return self.provider[0..self.provider_len];
}
