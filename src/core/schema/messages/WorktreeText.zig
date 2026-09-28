/// The text a worktree carries on the wire, in the runtime's table and in a
/// checkpoint. One rule set for all three, so a row the runtime accepts always
/// encodes into every client's workspace list.
const WorktreeText = @This();

path: []const u8,
branch: []const u8,
base: []const u8 = "",
title: []const u8 = "",
brief: []const u8 = "",
dispatched_from: []const u8 = "",
