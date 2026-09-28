const id = @import("../id.zig");
const types = @import("../types.zig");
/// Asks the runtime to track one Git linked worktree. The CLI adds the
/// checkout first; the runtime never runs Git on a client's behalf. A path
/// the runtime already tracks returns the existing worktree.
const RegisterWorktree = @This();

request_id: id.RequestId,
/// The workspace the worktree hangs from in every client.
source: id.WorkspaceId,
/// The pane that asked for it, so a coordinator's delegations stay traceable.
created_by: ?id.PaneId = null,
origin: types.WorktreeOrigin = .telar,
path: []const u8,
branch: []const u8,
/// The branch the worktree was created from, for review and integration.
base: []const u8 = "",
title: []const u8 = "",
brief: []const u8 = "",
/// The label of the machine that dispatched the worktree here, when another
/// machine did. Attribution only: the runtime never reaches that machine.
dispatched_from: []const u8 = "",
