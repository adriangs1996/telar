//! Git observation for tracked worktrees, on a worker: whether the checkout
//! still exists, its branch, local changes and diff against its base.

const std = @import("std");
const core = @import("telar-core");
const gitstatus = @import("gitstatus");
const WorktreeProbeJob = @import("WorktreeProbeJob.zig");
const WorktreeProbeCompletion = @import("WorktreeProbeCompletion.zig");
const WorktreeProbe = @import("../../workspace/WorktreeProbe.zig");

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
    if (gitstatus.probe.run(job.io, job.environ, path, &head_buffer)) |status| {
        // A branch the row cannot hold whole keeps the recorded one.
        if (fitsRow(path, status.branch)) {
            completion.branch_len = @intCast(status.branch.len);
            @memcpy(completion.branch[0..status.branch.len], status.branch);
        }

        completion.dirty = status.dirty;
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

    if (gitstatus.base_distance.run(job.io, .{ .environ = job.environ, .path = path }, base)) |measured| {
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

test "a worktree registered without a base is measured against its main checkout's branch" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try temp.dir.realPath(io, &root_buffer)];
    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main = try std.fmt.bufPrint(&main_buffer, "{s}/main", .{root});
    var linked_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const linked = try std.fmt.bufPrint(&linked_buffer, "{s}/external", .{root});

    testGit(&.{ "git", "init", "-q", "-b", "trunk", main }) catch return error.SkipZigTest;
    try temp.dir.writeFile(io, .{ .sub_path = "main/a.txt", .data = "one\n" });
    try testGit(&.{ "git", "-C", main, "add", "a.txt" });
    try testGit(&.{ "git", "-C", main, "-c", "user.name=telar", "-c", "user.email=telar@localhost", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "one" });
    try testGit(&.{ "git", "-C", main, "worktree", "add", "-q", "-b", "by-hand", linked });
    try temp.dir.writeFile(io, .{ .sub_path = "external/a.txt", .data = "one\ntwo\n" });
    try testGit(&.{ "git", "-C", linked, "-c", "user.name=telar", "-c", "user.email=telar@localhost", "-c", "commit.gpgsign=false", "commit", "-q", "-am", "two" });

    var request: WorktreeProbe = .{
        .worktree = @enumFromInt(1),
        .path_len = @intCast(linked.len),
        .base_len = 0,
    };
    @memcpy(request.path[0..linked.len], linked);
    const completion = probe(.{ .io = io, .environ = std.testing.environ, .request = request });

    try std.testing.expect(completion.measured);
    try std.testing.expectEqualStrings("trunk", completion.foundBaseSlice());
    try std.testing.expectEqual(@as(u32, 1), completion.stat.commits_ahead);
    try std.testing.expectEqual(@as(u32, 1), completion.stat.added);
}

fn testGit(argv: []const []const u8) !void {
    const result = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = argv });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        return error.GitFailed;
    }
}

test "a branch the row cannot hold whole is not reported" {
    try std.testing.expect(fitsRow("/w/fix", "fix/tabs"));
    try std.testing.expect(!fitsRow("/w/fix", "b" ** (core.max_git_branch_bytes + 1)));
    try std.testing.expect(!fitsRow("/w/fix", "fix-\xc3"));
    try std.testing.expect(!fitsRow("/w/fix", ""));
}
