const PaneKeyType = @import("../pane/PaneKey.zig");
const max_agent_session_title_bytes_module = @import("telar-core").max_agent_session_title_bytes;
/// What one probe found: the next transcript offset and, when a name was
/// read, the current one. An empty name clears the title.
const Completion = @This();

key: PaneKeyType,
offset: ?u64,
title: [max_agent_session_title_bytes_module]u8 = undefined,
title_len: u8 = 0,
has_title: bool = false,

pub fn titleSlice(completion: *const Completion) []const u8 {
    return completion.title[0..completion.title_len];
}

pub fn setTitle(completion: *Completion, value: []const u8) void {
    @memcpy(completion.title[0..value.len], value);
    completion.title_len = @intCast(value.len);
    completion.has_title = true;
}
