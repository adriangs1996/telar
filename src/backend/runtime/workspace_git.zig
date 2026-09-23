//! The maintenance tick probes the stalest workspace's Git branch and dirty
//! state on a worker; a changed result reaches every client's workspace list.

const core = @import("telar-core");
const std = @import("std");
const RuntimeModel = @import("RuntimeModel.zig");
const Workspaces = @import("../workspace/Workspaces.zig");
const Probe = @import("../workspace/Probe.zig");
const Completion = @import("resources/Completion.zig");
const Job = @import("resources/Job.zig");
const git_probe = @import("resources/git_probe.zig");

/// Starts one due probe, rolling back its reservation on scheduling failure.
///
/// ```zig
/// workspace_git.start(model);
/// ```
pub fn start(model: *RuntimeModel) void {
    const now_ms = std.Io.Timestamp.now(model.io, .real).toMilliseconds();
    const request = reserve(&model.workspaces, now_ms, git_probe.probe_interval_ms) orelse return;

    model.select.concurrent(.git_status, git_probe.probe, .{Job{
        .io = model.io,
        .request = request,
    }}) catch cancel(&model.workspaces, request.workspace);
}

/// Commits only the outstanding probe's result.
///
/// ```zig
/// workspace_git.finish(model, completion);
/// ```
pub fn finish(model: *RuntimeModel, completion: Completion) void {
    const branch = if (completion.present) completion.branchSlice() else "";
    const dirty = completion.present and completion.dirty;
    _ = commit(&model.workspaces, completion.workspace, branch, dirty, std.Io.Timestamp.now(model.io, .real).toMilliseconds());
}

/// Reserves the stalest due workspace and copies its path for the worker.
fn reserve(workspaces: *Workspaces, now_ms: i64, interval_ms: i64) ?Probe {
    if (workspaces.git_probe != null) {
        return null;
    }

    var stalest: ?usize = null;
    var rows = workspaces.visible.iterator(.{});
    while (rows.next()) |slot| {
        if (now_ms -| workspaces.git_checked_at_ms[slot] < interval_ms) {
            continue;
        }

        if (stalest == null or workspaces.git_checked_at_ms[slot] < workspaces.git_checked_at_ms[stalest.?]) {
            stalest = slot;
        }
    }

    const slot = stalest orelse return null;
    const path = workspaces.path[slot];
    var probe: Probe = .{ .workspace = workspaces.id[slot], .path_len = @intCast(path.len) };
    @memcpy(probe.path[0..path.len], path);
    workspaces.git_probe = workspaces.id[slot];
    return probe;
}

/// Cancels only the matching reservation, including a removed workspace's.
fn cancel(workspaces: *Workspaces, workspace: core.WorkspaceId) void {
    if (workspaces.git_probe == workspace) {
        workspaces.git_probe = null;
    }
}

/// Retires the reservation, stores the observation and advances the list
/// revision only when the branch or dirty state changed.
fn commit(workspaces: *Workspaces, workspace: core.WorkspaceId, branch: []const u8, dirty: bool, checked_at_ms: i64) bool {
    if (workspaces.git_probe != workspace) {
        return false;
    }

    cancel(workspaces, workspace);
    const slot = workspaces.slotOf(.{ .workspace = workspace }) orelse return false;
    workspaces.git_checked_at_ms[slot] = checked_at_ms;

    const bounded = branch[0..@min(branch.len, core.max_git_branch_bytes)];
    const changed = !std.mem.eql(u8, workspaces.gitBranch(slot), bounded) or workspaces.git_dirty[slot] != dirty;
    @memcpy(workspaces.git_branch[slot][0..bounded.len], bounded);
    workspaces.git_branch_len[slot] = @intCast(bounded.len);
    workspaces.git_dirty[slot] = dirty;

    if (changed) {
        workspaces.advanceRevision();
    }

    return changed;
}

test "Git probes reserve one workspace, reject stale results and recover after removal" {
    const gpa = std.testing.allocator;
    const workspaces = try gpa.create(Workspaces);
    defer gpa.destroy(workspaces);
    workspaces.* = .{};
    defer workspaces.deinit(gpa);
    const first = try workspaces.insert(gpa, "/first", null);
    _ = try workspaces.insert(gpa, "/second", null);

    const probe = reserve(workspaces, 5000, 5000).?;
    try std.testing.expectEqualStrings("/first", probe.pathSlice());
    try std.testing.expect(reserve(workspaces, 5000, 5000) == null);
    cancel(workspaces, @enumFromInt(999));
    try std.testing.expect(reserve(workspaces, 5000, 5000) == null);
    cancel(workspaces, probe.workspace);
    _ = reserve(workspaces, 5000, 5000).?;

    try std.testing.expect(commit(workspaces, probe.workspace, "main", true, 5000));
    const revision = workspaces.revision;
    try std.testing.expect(!commit(workspaces, probe.workspace, "main", true, 5000));
    try std.testing.expectEqual(revision, workspaces.revision);

    const second = reserve(workspaces, 5000, 5000).?;
    try std.testing.expectEqualStrings("/second", second.pathSlice());
    try std.testing.expect(workspaces.remove(gpa, second.workspace));
    try std.testing.expect(!commit(workspaces, second.workspace, "main", false, 5000));
    try std.testing.expect(reserve(workspaces, 5000, 5000) == null);
    try std.testing.expectEqual(first.workspace.workspace, reserve(workspaces, 10000, 5000).?.workspace);
}
