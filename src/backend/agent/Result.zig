const Result = @This();
const pane_mod = @import("../pane/root.zig");
const source_namespace = @import("description.zig");
pane: pane_mod.PaneKey,
session_id: [16]u8,
status: source_namespace.ResultStatus,
title: [source_namespace.schema.max_agent_session_title_bytes]u8 = undefined,
title_len: u8 = 0,

pub fn titleSlice(result: *const Result) []const u8 {
    return result.title[0..result.title_len];
}
