const PaneKeyType = @import("../pane/PaneKey.zig");
const description = @import("description.zig");
const max_agent_session_title_bytes_module = @import("telar-core").max_agent_session_title_bytes;
const Result = @This();

pane: PaneKeyType,
session_id: [16]u8,
status: description.ResultStatus,
title: [max_agent_session_title_bytes_module]u8 = undefined,
title_len: u8 = 0,

pub fn titleSlice(result: *const Result) []const u8 {
    return result.title[0..result.title_len];
}
