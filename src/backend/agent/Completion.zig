/// What one probe found: the next transcript offset and, when a name was
/// read, the current one. An empty name clears the title.
const Completion = @This();
const source_namespace = @import("session_file.zig");
key: source_namespace.PaneKey,
offset: ?u64,
title: [source_namespace.schema.max_agent_session_title_bytes]u8 = undefined,
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
