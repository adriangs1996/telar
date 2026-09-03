//! Git branch and cleanliness observation for workspaces.
//!
//! Probing runs on the observation path: the maintenance tick starts at most
//! one bounded worker for the stalest workspace, the worker reads `.git/HEAD`
//! and runs one time-limited `git status`, and the completion updates the
//! aggregate and the workspace-list revision.

const std = @import("std");
const core = @import("telar-core");
const workspace_mod = @import("../../workspace/root.zig");

const Io = std.Io;
const schema = core.schema;

pub const probe_interval_ms: i64 = 5_000;
pub const max_status_bytes = 64 * 1024;

const status_timeout: Io.Timeout = .{
    .duration = .{ .clock = .awake, .raw = .fromSeconds(2) },
};

pub const Job = struct {
    io: Io,
    workspace: schema.WorkspaceId,
    path: [std.fs.max_path_bytes]u8 = undefined,
    path_len: u16 = 0,

    pub fn pathSlice(job: *const Job) []const u8 {
        return job.path[0..job.path_len];
    }
};

pub const Completion = struct {
    workspace: schema.WorkspaceId,
    present: bool = false,
    branch: [schema.max_git_branch_bytes]u8 = undefined,
    branch_len: u8 = 0,
    dirty: bool = false,

    pub fn branchSlice(completion: *const Completion) []const u8 {
        return completion.branch[0..completion.branch_len];
    }
};

/// Runs on a worker: never touches runtime state.
///
/// ```zig
/// const completion = probe(job);
/// ```
pub fn probe(job: Job) Completion {
    var completion: Completion = .{ .workspace = job.workspace };
    var head_buffer: [4096]u8 = undefined;
    const head = readHead(job.io, job.pathSlice(), &head_buffer) orelse return completion;
    const branch = parseHead(head);
    completion.present = true;
    completion.branch_len = @intCast(@min(branch.len, completion.branch.len));
    @memcpy(completion.branch[0..completion.branch_len], branch[0..completion.branch_len]);
    completion.dirty = statusDirty(job.io, job.pathSlice());
    return completion;
}

fn readHead(io: Io, workspace_path: []const u8, buffer: []u8) ?[]const u8 {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const head_path = std.fmt.bufPrint(&path_buffer, "{s}/.git/HEAD", .{workspace_path}) catch return null;
    if (readSmall(io, head_path, buffer)) |bytes| {
        return bytes;
    }

    // A linked worktree keeps `.git` as a file pointing at its real git dir.
    var gitfile_buffer: [4096]u8 = undefined;
    const gitfile_path = std.fmt.bufPrint(&path_buffer, "{s}/.git", .{workspace_path}) catch return null;
    const gitfile = readSmall(io, gitfile_path, &gitfile_buffer) orelse return null;
    const trimmed = std.mem.trim(u8, gitfile, " \r\n");
    if (!std.mem.startsWith(u8, trimmed, "gitdir:")) {
        return null;
    }
    const git_dir = std.mem.trim(u8, trimmed["gitdir:".len..], " \r\n");
    const linked_head = std.fmt.bufPrint(&path_buffer, "{s}/HEAD", .{git_dir}) catch return null;
    return readSmall(io, linked_head, buffer);
}

fn readSmall(io: Io, path: []const u8, buffer: []u8) ?[]const u8 {
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    var reader = file.readerStreaming(io, &.{});
    const len = reader.interface.readSliceShort(buffer) catch return null;
    return buffer[0..len];
}

/// Extracts a branch name from `.git/HEAD` contents: the ref's last
/// component, or the short commit hash of a detached head.
///
/// ```zig
/// const branch = parseHead("ref: refs/heads/main\n");
/// ```
pub fn parseHead(bytes: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, bytes, " \r\n");
    if (std.mem.startsWith(u8, trimmed, "ref:")) {
        const reference = std.mem.trim(u8, trimmed[4..], " ");
        if (std.mem.startsWith(u8, reference, "refs/heads/")) {
            return reference["refs/heads/".len..];
        }
        return reference;
    }

    return trimmed[0..@min(trimmed.len, 8)];
}

fn statusDirty(io: Io, workspace_path: []const u8) bool {
    const gpa = std.heap.page_allocator;
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "git", "-C", workspace_path, "status", "--porcelain", "--no-renames" },
        .stdout_limit = .limited(max_status_bytes),
        .stderr_limit = .limited(4096),
        .timeout = status_timeout,
    }) catch return false;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        return false;
    }
    return std.mem.trim(u8, result.stdout, " \r\n").len != 0;
}

/// Binds probing to one application type providing `io`, `select`,
/// `workspaceRepository()`, `git_probe_in_flight` and `pumpAll`.
pub fn Observer(comptime Application: type) type {
    return struct {
        /// Starts one probe for the stalest due workspace, if any.
        ///
        /// ```zig
        /// GitObserver.tick(&application);
        /// ```
        pub fn tick(application: *Application) void {
            if (application.git_probe_in_flight) {
                return;
            }
            const now_ms = Io.Timestamp.now(application.io, .real).toMilliseconds();
            var repository = application.workspaceRepository();

            var stalest: ?*workspace_mod.Workspace = null;
            for (&repository.state.items) |*slot| {
                const workspace = if (slot.*) |*value| value else continue;
                if (workspace.git_probe_pending) {
                    continue;
                }
                if (now_ms - workspace.git_checked_at_ms < probe_interval_ms) {
                    continue;
                }
                if (stalest == null or workspace.git_checked_at_ms < stalest.?.git_checked_at_ms) {
                    stalest = workspace;
                }
            }

            const workspace = stalest orelse return;
            var job: Job = .{ .io = application.io, .workspace = workspace.id };
            const path = workspace.pathSlice();
            if (path.len > job.path.len) {
                return;
            }
            @memcpy(job.path[0..path.len], path);
            job.path_len = @intCast(path.len);

            workspace.git_probe_pending = true;
            application.git_probe_in_flight = true;
            application.select.concurrent(.git_status, probe, .{job}) catch {
                workspace.git_probe_pending = false;
                application.git_probe_in_flight = false;
            };
        }

        /// Applies one probe result and publishes a changed list projection.
        ///
        /// ```zig
        /// GitObserver.handleCompletion(&application, completion);
        /// ```
        pub fn handleCompletion(application: *Application, completion: Completion) void {
            application.git_probe_in_flight = false;
            var repository = application.workspaceRepository();
            const workspace = repository.find(.{ .workspace = completion.workspace }) orelse return;
            workspace.git_probe_pending = false;
            workspace.git_checked_at_ms = Io.Timestamp.now(application.io, .real).toMilliseconds();

            const branch = if (completion.present) completion.branchSlice() else "";
            const dirty = completion.present and completion.dirty;
            if (workspace.applyGitStatus(branch, dirty)) {
                repository.recordListChange();
                application.pumpAll();
            }
        }
    };
}

test "HEAD contents resolve to a branch or a short detached hash" {
    try std.testing.expectEqualStrings("main", parseHead("ref: refs/heads/main\n"));
    try std.testing.expectEqualStrings("feature/x", parseHead("ref: refs/heads/feature/x"));
    try std.testing.expectEqualStrings("refs/tags/v1", parseHead("ref: refs/tags/v1\n"));
    try std.testing.expectEqualStrings("0a1b2c3d", parseHead("0a1b2c3d4e5f60718293a4b5c6d7e8f901234567\n"));
}
