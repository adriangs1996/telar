const core = @import("telar-core");
const PaneKey = @import("../pane/PaneKey.zig");
/// What one probe found: the next transcript offset and, when a name was
/// read, the current one. An empty name clears the title.
const Completion = @This();

key: PaneKey,
offset: ?u64,
title: [core.max_agent_session_title_bytes]u8 = undefined,
title_len: u8 = 0,
has_title: bool = false,

pub fn titleSlice(self: *const Completion) []const u8 {
    return self.title[0..self.title_len];
}

pub fn setTitle(self: *Completion, value: []const u8) void {
    @memcpy(self.title[0..value.len], value);
    self.title_len = @intCast(value.len);
    self.has_title = true;
}
