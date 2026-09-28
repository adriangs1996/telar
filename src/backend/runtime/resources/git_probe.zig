//! Git branch and cleanliness observation for workspaces.
//!
//! Probing runs on the observation path: the maintenance tick starts at most
//! one bounded worker for the stalest workspace, the worker asks `gitstatus`
//! for the branch and cleanliness, and the completion updates the aggregate
//! and the workspace-list revision.

const gitstatus = @import("gitstatus");
const Job = @import("Job.zig");
const Completion = @import("Completion.zig");

pub const probe_interval_ms: i64 = 5_000;

/// Runs on a worker: never touches runtime state.
///
/// ```zig
/// const completion = probe(job);
/// ```
pub fn probe(job: Job) Completion {
    var completion: Completion = .{ .workspace = job.request.workspace };
    var head_buffer: [4096]u8 = undefined;
    const status = gitstatus.probe.run(job.io, job.environ, job.request.pathSlice(), &head_buffer) orelse return completion;
    completion.present = true;
    completion.branch_len = @intCast(@min(status.branch.len, completion.branch.len));
    @memcpy(completion.branch[0..completion.branch_len], status.branch[0..completion.branch_len]);
    completion.dirty = status.dirty;
    return completion;
}
