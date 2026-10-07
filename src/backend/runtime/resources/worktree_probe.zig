//! Git observation for tracked worktrees, on a worker: whether the checkout
//! still exists, its branch, local changes and diff against its base.

const std = @import("std");
const core = @import("telar-core");
const gitstatus = @import("gitstatus");
const WorktreeProbeJob = @import("WorktreeProbeJob.zig");
const WorktreeProbeCompletion = @import("WorktreeProbeCompletion.zig");
const git_probe = @import("git_probe.zig");

/// A worktree running a command is measured this often.
pub const active_interval_ms: i64 = 5_000;
/// A quiet worktree is measured this often.
pub const idle_interval_ms: i64 = 30_000;
/// After this many failed measurements a worktree waits for the idle interval.
pub const max_failures = 2;
/// A Git step of the base measurement past this leaves the diff unknown.
pub const base_distance_timeout_limit = core.Limit.declare("gitstatus.base_distance_timeout", "milliseconds", gitstatus.base_distance.git_timeout_ms);

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
    var status_known = false;
    if (gitstatus.probe.run(job.io, job.environ, path, &head_buffer)) |status| {
        // A branch the row cannot hold whole keeps the recorded one.
        if (fitsRow(path, status.branch)) {
            completion.branch_len = @intCast(status.branch.len);
            @memcpy(completion.branch[0..status.branch.len], status.branch);
        }

        if (status.dirty) |dirty| {
            completion.dirty = dirty;
            status_known = true;
        }

        if (status.timed_out) {
            completion.limit = .{
                .limit = git_probe.status_timeout_limit,
            };
        }
    }

    // A worktree found by observation has no base; measure it against the
    // branch its main checkout stands on, as `telar worktree create` would.
    var base = job.request.baseSlice();
    var main_head: [256]u8 = undefined;
    if (base.len == 0) {
        if (gitstatus.linked_worktree.mainBranch(job.io, path, &main_head)) |main_branch| {
            if (fitsRow(path, main_branch)) {
                completion.found_base_len = @intCast(main_branch.len);
                @memcpy(completion.found_base[0..main_branch.len], main_branch);
                base = completion.foundBaseSlice();
            }
        }
    }

    // A measurement needs both halves: local changes and the diff.
    if (!status_known) {
        return completion;
    }

    if (gitstatus.base_distance.run(job.io, .{ .environ = job.environ, .path = path }, base)) |measured| {
        completion.measured = true;
        completion.stat = measured;
    } else |err| {
        if (err == error.GitTimedOut) {
            completion.limit = .{
                .limit = base_distance_timeout_limit,
            };
        }
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
