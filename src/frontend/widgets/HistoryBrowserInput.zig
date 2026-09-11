const picker = @import("goto_picker.zig");
const Entry = @import("Entry.zig");
const Input = @This();

field: *picker.Field,
entries: []const Entry,
selection: u16,
scope: []const u8,
inspecting: bool = false,
detail_scroll: u32 = 0,
now_ms: i64 = 0,
enter_runs: bool = false,
match_fuzzy: bool = true,
loading: bool = false,
error_text: []const u8 = "",
output: []const u8 = "",
output_hint: []const u8 = "No captured output",
graphical_frame: bool = false,
page_offset: u32 = 0,
has_more: bool = false,
