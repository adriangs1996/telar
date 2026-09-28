//! The maintenance tick measures the stalest due worktree on a worker: its
//! diff against its base, commits ahead and local changes. A worktree running
//! a command is measured more often than a quiet one, one probe is in flight
//! at a time, and a changed result reaches every client's workspace list.
//! See `docs/flows/worktree-git.md`.

const std = @import("std");
const core = @import("telar-core");
const RuntimeModel = @import("RuntimeModel.zig");
const Worktrees = @import("../workspace/Worktrees.zig");
const WorktreeProbe = @import("../workspace/WorktreeProbe.zig");
const WorktreeProbeCompletion = @import("resources/WorktreeProbeCompletion.zig");
const worktree_probe = @import("resources/worktree_probe.zig");
const WorktreeProbeJob = @import("resources/WorktreeProbeJob.zig");
const session_checkpoint = @import("session_checkpoint.zig");

/// Starts one due probe, rolling back its reservation on scheduling failure.
///
/// ```zig
/// worktree_git.start(model);
/// ```
pub fn start(model: *RuntimeModel) void {
    const now_ms = std.Io.Timestamp.now(model.io, .real).toMilliseconds();
    const request = reserve(&model.worktrees, now_ms) orelse return;

    model.select.concurrent(.worktree_git, worktree_probe.probe, .{WorktreeProbeJob{
        .io = model.io,
        .environ = model.inherited_environment,
        .request = request,
    }}) catch cancel(&model.worktrees, request.worktree);
}

/// Commits only the outstanding probe's result.
///
/// ```zig
/// worktree_git.finish(model, completion);
/// ```
pub fn finish(model: *RuntimeModel, completion: WorktreeProbeCompletion) void {
    const now_ms = std.Io.Timestamp.now(model.io, .real).toMilliseconds();
    if (commit(&model.worktrees, completion, now_ms)) {
        model.workspaces.advanceRevision();
    }

    // A base learned by the probe is recorded; it is found once per row.
    if (completion.found_base_len != 0) {
        session_checkpoint.noteChange(model);
    }
}

fn reserve(worktrees: *Worktrees, now_ms: i64) ?WorktreeProbe {
    if (worktrees.git_probe != null) {
        return null;
    }

    var stalest: ?usize = null;
    var rows = worktrees.rows.iterator(.{});
    while (rows.next()) |slot| {
        if (worktrees.state[slot] == .gone) {
            continue;
        }

        if (now_ms -| worktrees.git_checked_at_ms[slot] < interval(worktrees, slot)) {
            continue;
        }

        if (stalest == null or worktrees.git_checked_at_ms[slot] < worktrees.git_checked_at_ms[stalest.?]) {
            stalest = slot;
        }
    }

    const slot = stalest orelse return null;
    const path = worktrees.path[slot];
    const base = worktrees.baseAt(slot);
    var probe: WorktreeProbe = .{
        .worktree = worktrees.id[slot],
        .path_len = @intCast(path.len),
        .base_len = @intCast(base.len),
    };
    @memcpy(probe.path[0..path.len], path);
    @memcpy(probe.base[0..base.len], base);
    worktrees.git_probe = worktrees.id[slot];
    return probe;
}

/// A worktree running a command changes fast; a quiet one, or one whose
/// measurements keep failing, waits longer.
fn interval(worktrees: *const Worktrees, slot: usize) i64 {
    if (worktrees.command_state[slot] == .running and worktrees.probe_failures[slot] < worktree_probe.max_failures) {
        return worktree_probe.active_interval_ms;
    }

    return worktree_probe.idle_interval_ms;
}

fn cancel(worktrees: *Worktrees, worktree: core.WorktreeId) void {
    if (worktrees.git_probe == worktree) {
        worktrees.git_probe = null;
    }
}

/// Retires the reservation and stores the observation. Returns whether a
/// value clients see changed.
fn commit(worktrees: *Worktrees, completion: WorktreeProbeCompletion, now_ms: i64) bool {
    if (worktrees.git_probe != completion.worktree) {
        return false;
    }

    cancel(worktrees, completion.worktree);
    const slot = worktrees.slotOf(completion.worktree) orelse return false;
    worktrees.git_checked_at_ms[slot] = now_ms;
    const before = observed(worktrees, slot);

    if (!completion.present) {
        worktrees.state[slot] = .gone;
        return !std.meta.eql(before, observed(worktrees, slot));
    }

    worktrees.git_dirty[slot] = completion.dirty;
    const found_base = completion.foundBaseSlice();
    const learned_base = found_base.len != 0 and worktrees.base_len[slot] == 0;
    if (learned_base) {
        @memcpy(worktrees.base[slot][0..found_base.len], found_base);
        worktrees.base_len[slot] = @intCast(found_base.len);
    }

    const branch = completion.branchSlice();
    if (branch.len != 0) {
        @memcpy(worktrees.branch[slot][0..branch.len], branch);
        worktrees.branch_len[slot] = @intCast(branch.len);
    }

    if (completion.measured) {
        worktrees.probe_failures[slot] = 0;
        worktrees.diff_added[slot] = completion.stat.added;
        worktrees.diff_removed[slot] = completion.stat.removed;
        worktrees.diff_files[slot] = completion.stat.files;
        worktrees.commits_ahead[slot] = completion.stat.commits_ahead;
    } else {
        worktrees.probe_failures[slot] +|= 1;
    }

    const pending = completion.dirty or worktrees.diff_files[slot] != 0 or worktrees.commits_ahead[slot] != 0;
    if (pending) {
        worktrees.had_changes[slot] = true;
    }

    worktrees.state[slot] = if (!pending and worktrees.had_changes[slot]) .integrated else .active;
    return learned_base or !std.meta.eql(before, observed(worktrees, slot));
}

const Observed = struct {
    state: core.WorktreeState,
    added: u32,
    removed: u32,
    files: u32,
    ahead: u32,
    branch_len: u8,
    branch: [core.max_git_branch_bytes]u8,
};

fn observed(worktrees: *const Worktrees, slot: usize) Observed {
    var value: Observed = .{
        .state = worktrees.state[slot],
        .added = worktrees.diff_added[slot],
        .removed = worktrees.diff_removed[slot],
        .files = worktrees.diff_files[slot],
        .ahead = worktrees.commits_ahead[slot],
        .branch_len = worktrees.branch_len[slot],
        .branch = @splat(0),
    };
    @memcpy(value.branch[0..value.branch_len], worktrees.branchAt(slot));
    return value;
}

test "a clean worktree turns integrated only after it held work, and a missing checkout is gone" {
    const gpa = std.testing.allocator;
    const table = try gpa.create(Worktrees);
    defer gpa.destroy(table);
    table.* = .{};
    defer table.deinit(gpa);
    const registered = try table.register(gpa, .{
        .source = @enumFromInt(1),
        .path = "/w/fix",
        .branch = "fix",
        .base = "main",
    });

    table.git_probe = registered.id;
    try std.testing.expect(!commit(table, .{ .worktree = registered.id, .present = true, .measured = true }, 10));
    try std.testing.expectEqual(core.WorktreeState.active, table.state[registered.slot]);

    table.git_probe = registered.id;
    try std.testing.expect(commit(table, .{ .worktree = registered.id, .present = true, .measured = true, .stat = .{ .added = 3, .files = 1, .commits_ahead = 1 } }, 20));
    try std.testing.expectEqual(@as(u32, 3), table.diff_added[registered.slot]);

    table.git_probe = registered.id;
    try std.testing.expect(commit(table, .{ .worktree = registered.id, .present = true, .measured = true }, 30));
    try std.testing.expectEqual(core.WorktreeState.integrated, table.state[registered.slot]);

    table.git_probe = registered.id;
    try std.testing.expect(commit(table, .{ .worktree = registered.id }, 40));
    try std.testing.expectEqual(core.WorktreeState.gone, table.state[registered.slot]);
    try std.testing.expect(reserve(table, 100_000) == null);
}

test "a base the probe found is kept once and a recorded base is never replaced" {
    const gpa = std.testing.allocator;
    const table = try gpa.create(Worktrees);
    defer gpa.destroy(table);
    table.* = .{};
    defer table.deinit(gpa);
    const external = try table.register(gpa, .{
        .source = @enumFromInt(1),
        .origin = .external,
        .path = "/w/by-hand",
        .branch = "by-hand",
    });

    var found: WorktreeProbeCompletion = .{ .worktree = external.id, .present = true, .measured = true };
    found.found_base_len = 4;
    @memcpy(found.found_base[0..4], "main");
    table.git_probe = external.id;
    try std.testing.expect(commit(table, found, 10));
    try std.testing.expectEqualStrings("main", table.baseAt(external.slot));

    @memcpy(found.found_base[0..4], "next");
    table.git_probe = external.id;
    _ = commit(table, found, 20);
    try std.testing.expectEqualStrings("main", table.baseAt(external.slot));
}

test "a stale completion leaves the table untouched" {
    const gpa = std.testing.allocator;
    const table = try gpa.create(Worktrees);
    defer gpa.destroy(table);
    table.* = .{};
    defer table.deinit(gpa);
    const registered = try table.register(gpa, .{
        .source = @enumFromInt(1),
        .path = "/w/fix",
        .branch = "fix",
    });

    try std.testing.expect(!commit(table, .{ .worktree = registered.id, .present = false }, 10));
    try std.testing.expectEqual(core.WorktreeState.active, table.state[registered.slot]);
}
