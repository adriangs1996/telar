const std = @import("std");
const core = @import("telar-core");
const PaneKey = @import("../../pane/PaneKey.zig");
/// One pane's directory, copied for the worker that looks for the linked
/// worktree it lies in.
const WorktreeDetectionJob = @This();

io: std.Io,
pane: PaneKey,
/// The pane's cwd revision when copied; a later one makes the answer stale.
cwd_revision: u64,
cwd: [core.max_cwd_bytes]u8 = undefined,
cwd_len: u16,

pub fn cwdSlice(self: *const WorktreeDetectionJob) []const u8 {
    return self.cwd[0..self.cwd_len];
}
