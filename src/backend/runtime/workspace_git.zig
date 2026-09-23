//! The maintenance tick probes the stalest workspace's Git branch and dirty
//! state on a worker; a changed result reaches every client's workspace list.

const std = @import("std");
const RuntimeModel = @import("RuntimeModel.zig");
const Completion = @import("resources/Completion.zig");
const Job = @import("resources/Job.zig");
const git_probe = @import("resources/git_probe.zig");

/// Starts one due probe, rolling back its reservation on scheduling failure.
///
/// ```zig
/// workspace_git.start(model);
/// ```
pub fn start(model: *RuntimeModel) void {
    var repository = model.workspaceRepository();
    const request = repository.reserveGitProbe(.{
        .now_ms = std.Io.Timestamp.now(model.io, .real).toMilliseconds(),
        .interval_ms = git_probe.probe_interval_ms,
    }) orelse return;

    model.select.concurrent(.git_status, git_probe.probe, .{Job{
        .io = model.io,
        .request = request,
    }}) catch repository.cancelGitProbe(request.workspace);
}

/// Commits only the outstanding probe's result.
///
/// ```zig
/// workspace_git.finish(model, completion);
/// ```
pub fn finish(model: *RuntimeModel, completion: Completion) void {
    var repository = model.workspaceRepository();
    _ = repository.completeGitProbe(.{
        .workspace = completion.workspace,
        .branch = if (completion.present) completion.branchSlice() else "",
        .dirty = completion.present and completion.dirty,
        .checked_at_ms = std.Io.Timestamp.now(model.io, .real).toMilliseconds(),
    });
}
