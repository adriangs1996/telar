//! A shell, or an agent without hooks, can work in a linked worktree telar
//! never created. When a pane's directory changes, a worker reads the `.git`
//! files above it (no Git process) and a linked worktree it finds is tracked
//! as `external`, under the pane's project. One detection is in flight; the
//! next pane waits for it or for the maintenance tick.

const std = @import("std");
const core = @import("telar-core");
const gitstatus = @import("gitstatus");
const RuntimeModel = @import("RuntimeModel.zig");
const WorktreeDetectionJob = @import("resources/WorktreeDetectionJob.zig");
const WorktreeDetectionCompletion = @import("resources/WorktreeDetectionCompletion.zig");
const worktree_lifecycle = @import("worktree_lifecycle.zig");

/// Starts one detection for the first pane whose directory changed since it
/// was last looked at, unless one is in flight.
///
/// ```zig
/// worktree_detection.start(model);
/// ```
pub fn start(model: *RuntimeModel) void {
    if (model.worktree_detection_in_flight) {
        return;
    }

    const job = reserve(model) orelse return;
    model.worktree_detection_in_flight = true;
    model.select.concurrent(.worktree_detected, detect, .{job}) catch {
        model.worktree_detection_in_flight = false;
        forget(model, job);
    };
}

/// Tracks the linked worktree a pane's directory lies in, when the pane is
/// still there and has not moved since, then starts the next detection.
///
/// ```zig
/// try worktree_detection.finish(model, completion);
/// ```
pub fn finish(model: *RuntimeModel, completion: WorktreeDetectionCompletion) !void {
    model.worktree_detection_in_flight = false;
    const tracked = track(model, completion);
    start(model);
    try tracked;
}

fn track(model: *RuntimeModel, completion: WorktreeDetectionCompletion) !void {
    if (completion.root_len == 0) {
        return;
    }

    const pane = model.panes.resolve(completion.pane) orelse return;
    const cwd = pane.cwd.slice();
    if (pane.cwd.revision != completion.cwd_revision or completion.root_len > cwd.len) {
        return;
    }

    const workspace = switch (pane.location.workspace) {
        .workspace => |id| id,
        .worktree => return,
    };

    const registered = model.worktrees.register(model.gpa, .{
        .source = model.worktrees.sourceFor(workspace),
        .origin = .external,
        .path = cwd[0..completion.root_len],
        .branch = completion.branchSlice(),
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };

    if (registered.created) {
        worktree_lifecycle.announce(model);
    }
}

/// The first pane whose directory changed since it was last looked at and
/// lies in no tracked worktree. Every pane it passes is marked as seen.
fn reserve(model: *RuntimeModel) ?WorktreeDetectionJob {
    const panes = &model.panes;
    for (panes.items, 0..) |item, slot| {
        const pane = item orelse continue;
        const revision = pane.cwd.revision;
        if (panes.worktree_checked_cwd[slot] == revision) {
            continue;
        }

        panes.worktree_checked_cwd[slot] = revision;
        const cwd = pane.cwd.slice();
        if (pane.exit != null or pane.location.workspace != .workspace or !std.fs.path.isAbsolute(cwd)) {
            continue;
        }

        if (model.worktrees.slotContaining(cwd) != null) {
            continue;
        }

        var job: WorktreeDetectionJob = .{
            .io = model.io,
            .pane = pane.key(),
            .cwd_revision = revision,
            .cwd_len = @intCast(cwd.len),
        };
        @memcpy(job.cwd[0..cwd.len], cwd);
        return job;
    }

    return null;
}

/// A job that never started leaves its pane to be looked at again.
fn forget(model: *RuntimeModel, job: WorktreeDetectionJob) void {
    const slot = model.panes.index.get(core.raw(job.pane.id)) orelse return;
    model.panes.worktree_checked_cwd[slot] = 0;
}

/// Runs on a worker: reads files only and never touches runtime state.
fn detect(job: WorktreeDetectionJob) WorktreeDetectionCompletion {
    const path = core.enter(.observation);
    defer path.restore();

    var completion: WorktreeDetectionCompletion = .{
        .pane = job.pane,
        .cwd_revision = job.cwd_revision,
    };
    var root: [core.max_cwd_bytes]u8 = undefined;
    var head: [256]u8 = undefined;
    const cwd = job.cwdSlice();
    const linked = gitstatus.linked_worktree.find(job.io, cwd, &root, &head) orelse return completion;
    core.validateWorktreeText(.{
        .path = linked.root,
        .branch = linked.branch,
    }) catch return completion;

    completion.root_len = @intCast(linked.root.len);
    completion.branch_len = @intCast(linked.branch.len);
    @memcpy(completion.branch[0..linked.branch.len], linked.branch);
    return completion;
}
