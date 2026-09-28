//! Git observation for tracked worktrees, on a worker: whether the checkout
//! still exists, its branch, local changes and diff against its base.

const std = @import("std");
const gitstatus = @import("gitstatus");
const WorktreeProbeJob = @import("WorktreeProbeJob.zig");
const WorktreeProbeCompletion = @import("WorktreeProbeCompletion.zig");

/// A worktree running a command is measured this often.
pub const active_interval_ms: i64 = 5_000;
/// A quiet worktree is measured this often.
pub const idle_interval_ms: i64 = 30_000;
/// After this many failed measurements a worktree waits for the idle interval.
pub const max_failures = 2;

/// Runs on a worker: never touches runtime state.
///
/// ```zig
/// const completion = worktree_probe.probe(job);
/// ```
pub fn probe(job: WorktreeProbeJob) WorktreeProbeCompletion {
    var completion: WorktreeProbeCompletion = .{ .worktree = job.request.worktree };
    const path = job.request.pathSlice();
    const stat = std.Io.Dir.cwd().statFile(job.io, path, .{}) catch return completion;
    if (stat.kind != .directory) {
        return completion;
    }

    completion.present = true;
    var head_buffer: [4096]u8 = undefined;
    if (gitstatus.probe.run(job.io, path, &head_buffer)) |status| {
        completion.branch_len = @intCast(@min(status.branch.len, completion.branch.len));
        @memcpy(completion.branch[0..completion.branch_len], status.branch[0..completion.branch_len]);
        completion.dirty = status.dirty;
    }

    if (gitstatus.base_distance.run(job.io, path, job.request.baseSlice())) |measured| {
        completion.measured = true;
        completion.stat = measured;
    }

    return completion;
}
