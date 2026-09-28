/// One tracked worktree in a checkpoint. Git observations and the running
/// command are not recorded; the next probe and launch rebuild them.
const WorktreeRecord = @This();

id: u64,
source_workspace_id: u64,
/// The workspace holding the worktree's tabs; zero when none.
workspace_id: u64 = 0,
/// The pane that asked for it; zero when unknown.
created_by: u64 = 0,
origin: u8 = 0,
path: []const u8,
branch: []const u8,
base: []const u8 = "",
title: []const u8 = "",
brief: []const u8 = "",
/// Written from version 7 on; empty before.
dispatched_from: []const u8 = "",
