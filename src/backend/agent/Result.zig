const core = @import("telar-core");
const PaneKey = @import("../pane/PaneKey.zig");
const description = @import("description.zig");
const Result = @This();

pane: PaneKey,
session_id: [16]u8,
status: description.ResultStatus,
title: [core.max_agent_session_title_bytes]u8 = undefined,
title_len: u8 = 0,

pub fn titleSlice(self: *const Result) []const u8 {
    return self.title[0..self.title_len];
}
