//! Git observation for tracked worktrees, on a worker: whether the checkout
//! still exists, its branch, local changes and diff against its base.

const std = @import("std");
const core = @import("telar-core");
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
        // A branch the row cannot hold whole keeps the recorded one.
        if (fitsRow(path, status.branch)) {
            completion.branch_len = @intCast(status.branch.len);
            @memcpy(completion.branch[0..status.branch.len], status.branch);
        }

        completion.dirty = status.dirty;
    }

    if (gitstatus.base_distance.run(job.io, path, job.request.baseSlice())) |measured| {
        completion.measured = true;
        completion.stat = measured;
    }

    return completion;
}

fn fitsRow(path: []const u8, branch: []const u8) bool {
    if (branch.len == 0) {
        return false;
    }

    core.validateWorktreeText(.{
        .path = path,
        .branch = branch,
    }) catch return false;
    return true;
}

test "a branch the row cannot hold whole is not reported" {
    try std.testing.expect(fitsRow("/w/fix", "fix/tabs"));
    try std.testing.expect(!fitsRow("/w/fix", "b" ** (core.max_git_branch_bytes + 1)));
    try std.testing.expect(!fitsRow("/w/fix", "fix-\xc3"));
    try std.testing.expect(!fitsRow("/w/fix", ""));
}
