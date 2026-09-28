//! Git as the CLI runs it for worktrees: the main checkout of a repository,
//! the branch it stands on, adding and removing linked worktrees and deleting
//! branches. Git runs in the CLI process with the user's environment and
//! credentials; the runtime never runs Git on a client's behalf. Branch names
//! are validated before they reach an argv and always sit after `--` or in a
//! position Git never parses as an option.

const std = @import("std");
const workspace = @import("arguments/workspace.zig");
const WorktreeCheckout = @import("WorktreeCheckout.zig");
const DiffRequest = @import("DiffRequest.zig");
const ListedWorktrees = @import("ListedWorktrees.zig");

const git_timeout: std.Io.Timeout = .{
    .duration = .{ .clock = .awake, .raw = .fromSeconds(60) },
};

const max_git_output_bytes = 64 * 1024;

/// The main checkout of the repository `directory` lies in, even when
/// `directory` is inside a linked worktree, so worktrees never nest.
///
/// ```zig
/// const root = try worktree_git.mainRoot(init, "/src/telar-worktrees/fix", &buffer);
/// // "/src/telar"
/// ```
pub fn mainRoot(init: std.process.Init, directory: []const u8, buffer: []u8) ![]const u8 {
    var output: [std.fs.max_path_bytes]u8 = undefined;
    const common = try gitLine(init, &.{ "git", "-C", directory, "rev-parse", "--path-format=absolute", "--git-common-dir" }, &output);
    const trimmed = std.mem.trimEnd(u8, common, "/");
    if (!std.mem.endsWith(u8, trimmed, "/.git")) {
        return error.NotARepository;
    }

    const root = trimmed[0 .. trimmed.len - "/.git".len];
    if (root.len == 0 or root.len > buffer.len or !std.fs.path.isAbsolute(root)) {
        return error.NotARepository;
    }

    @memcpy(buffer[0..root.len], root);
    return buffer[0..root.len];
}

/// The branch checked out at `root`, used as the base of a new worktree.
///
/// ```zig
/// const base = try worktree_git.currentBranch(init, root, &buffer);
/// ```
pub fn currentBranch(init: std.process.Init, root: []const u8, buffer: []u8) ![]const u8 {
    return gitLine(init, &.{ "git", "-C", root, "rev-parse", "--abbrev-ref", "HEAD" }, buffer);
}

/// Sibling directory `<parent>/<repo>-worktrees/<branch>` with path
/// separators in the branch name flattened to dashes, so the worktree never
/// lands inside the repository it mirrors.
///
/// ```zig
/// const directory = try worktree_git.deriveDirectory("/src/telar", "fix/tabs", &buffer);
/// // "/src/telar-worktrees/fix-tabs"
/// ```
pub fn deriveDirectory(root: []const u8, branch: []const u8, buffer: []u8) ![]const u8 {
    if (branch.len > workspace.max_worktree_branch_bytes) {
        return error.InvalidWorktreeBranch;
    }

    var sanitized: [workspace.max_worktree_branch_bytes]u8 = undefined;
    for (branch, 0..) |byte, index| {
        sanitized[index] = if (byte == '/' or byte == '\\') '-' else byte;
    }

    const parent = std.fs.path.dirname(root) orelse return error.InvalidRepository;
    const repository = std.fs.path.basename(root);
    if (repository.len == 0) {
        return error.InvalidRepository;
    }

    return std.fmt.bufPrint(buffer, "{s}/{s}-worktrees/{s}", .{ parent, repository, sanitized[0..branch.len] }) catch error.PathTooLong;
}

/// Checks out `branch` into `directory`, creating the branch from `base`
/// only when it does not exist yet.
///
/// ```zig
/// try worktree_git.add(init, .{ .root = root, .directory = dir, .branch = "fix", .base = "main" });
/// ```
pub fn add(init: std.process.Init, checkout: WorktreeCheckout) !void {
    try workspace.validateWorktreeBranch(checkout.branch);
    if (branchExists(init, checkout.root, checkout.branch)) {
        return run(init, &.{ "git", "-C", checkout.root, "worktree", "add", "--", checkout.directory, checkout.branch }, error.WorktreeAddFailed);
    }

    try workspace.validateWorktreeBranch(checkout.base);
    return run(init, &.{ "git", "-C", checkout.root, "worktree", "add", "-b", checkout.branch, "--", checkout.directory, checkout.base }, error.WorktreeAddFailed);
}

/// Removes the checkout at `directory`. Without `force`, Git refuses a
/// checkout with local changes, which is the safety the caller relies on.
///
/// ```zig
/// try worktree_git.remove(init, root, directory, false);
/// ```
pub fn remove(init: std.process.Init, root: []const u8, directory: []const u8, force: bool) !void {
    if (force) {
        return run(init, &.{ "git", "-C", root, "worktree", "remove", "--force", "--", directory }, error.WorktreeRemoveFailed);
    }

    return run(init, &.{ "git", "-C", root, "worktree", "remove", "--", directory }, error.WorktreeRemoveFailed);
}

/// Deletes a branch. Without `force`, Git refuses one that is not merged.
///
/// ```zig
/// try worktree_git.deleteBranch(init, root, "fix", false);
/// ```
pub fn deleteBranch(init: std.process.Init, root: []const u8, branch: []const u8, force: bool) !void {
    try workspace.validateWorktreeBranch(branch);
    const flag = if (force) "-D" else "-d";
    return run(init, &.{ "git", "-C", root, "branch", flag, "--", branch }, error.BranchDeleteFailed);
}

/// Whether the checkout has uncommitted changes or untracked files.
///
/// ```zig
/// if (try worktree_git.hasChanges(init, directory)) return error.WorktreeHasChanges;
/// ```
pub fn hasChanges(init: std.process.Init, directory: []const u8) !bool {
    const result = std.process.run(init.gpa, init.io, .{
        .argv = &.{ "git", "-C", directory, "status", "--porcelain" },
        .stdout_limit = .limited(max_git_output_bytes),
        .stderr_limit = .limited(4096),
        .timeout = git_timeout,
    }) catch return error.GitFailed;
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        return error.GitFailed;
    }

    return std.mem.trim(u8, result.stdout, " \r\n").len != 0;
}

/// Streams `git diff` for a worktree to this process's stdout.
///
/// ```zig
/// try worktree_git.diff(init, .{ .directory = dir, .base = "main", .scope = .branch, .stat = true });
/// ```
pub fn diff(init: std.process.Init, request: DiffRequest) !void {
    var merge_base_buffer: [64]u8 = undefined;
    const against = switch (request.scope) {
        .uncommitted => "HEAD",
        .branch => against: {
            try workspace.validateWorktreeBranch(request.base);
            break :against try gitLine(init, &.{ "git", "-C", request.directory, "merge-base", request.base, "HEAD" }, &merge_base_buffer);
        },
    };

    const argv: []const []const u8 = if (request.stat)
        &.{ "git", "-C", request.directory, "--no-pager", "diff", "--stat", against }
    else
        &.{ "git", "-C", request.directory, "--no-pager", "diff", against };
    var child = try std.process.spawn(init.io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(init.io);
    if (term != .exited or term.exited != 0) {
        return error.GitDiffFailed;
    }
}

/// Lists the linked worktrees of the repository at `root`. The caller frees
/// the returned bytes.
///
/// ```zig
/// const bytes = try worktree_git.listPorcelain(init, root);
/// defer init.gpa.free(bytes);
/// var listed = worktree_git.listed(bytes);
/// ```
pub fn listPorcelain(init: std.process.Init, root: []const u8) ![]u8 {
    const result = std.process.run(init.gpa, init.io, .{
        .argv = &.{ "git", "-C", root, "worktree", "list", "--porcelain" },
        .stdout_limit = .limited(max_git_output_bytes),
        .stderr_limit = .limited(4096),
        .timeout = git_timeout,
    }) catch return error.GitFailed;
    defer init.gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        init.gpa.free(result.stdout);
        return error.GitFailed;
    }

    return result.stdout;
}

pub fn listed(bytes: []const u8) ListedWorktrees {
    return .{ .lines = std.mem.splitScalar(u8, bytes, '\n') };
}

fn branchExists(init: std.process.Init, root: []const u8, branch: []const u8) bool {
    var ref_buffer: [workspace.max_worktree_branch_bytes + 16]u8 = undefined;
    const ref = std.fmt.bufPrint(&ref_buffer, "refs/heads/{s}", .{branch}) catch return false;
    var output: [256]u8 = undefined;
    _ = gitLine(init, &.{ "git", "-C", root, "rev-parse", "--verify", "--quiet", ref }, &output) catch return false;
    return true;
}

fn run(init: std.process.Init, argv: []const []const u8, failure: anyerror) !void {
    const result = std.process.run(init.gpa, init.io, .{
        .argv = argv,
        .stdout_limit = .limited(max_git_output_bytes),
        .stderr_limit = .limited(max_git_output_bytes),
        .timeout = git_timeout,
    }) catch return failure;
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("{s}", .{result.stderr});
        return failure;
    }
}

fn gitLine(init: std.process.Init, argv: []const []const u8, buffer: []u8) ![]const u8 {
    const result = std.process.run(init.gpa, init.io, .{
        .argv = argv,
        .stdout_limit = .limited(max_git_output_bytes),
        .stderr_limit = .limited(4096),
        .timeout = git_timeout,
    }) catch return error.NotARepository;
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        return error.NotARepository;
    }

    const line = std.mem.trim(u8, result.stdout, " \r\n");
    if (line.len == 0 or line.len > buffer.len) {
        return error.NotARepository;
    }

    @memcpy(buffer[0..line.len], line);
    return buffer[0..line.len];
}

test "worktree directories derive from the repository and branch" {
    var buffer: [512]u8 = undefined;
    const derived = try deriveDirectory("/src/telar", "fix/tabs", &buffer);
    try std.testing.expectEqualStrings("/src/telar-worktrees/fix-tabs", derived);

    try std.testing.expectError(error.InvalidRepository, deriveDirectory("/", "main", &buffer));

    var small: [8]u8 = undefined;
    try std.testing.expectError(error.PathTooLong, deriveDirectory("/src/telar", "main", &small));
}

test "porcelain listing skips the main checkout and detached worktrees" {
    const porcelain =
        "worktree /src/telar\nHEAD abc\nbranch refs/heads/main\n\n" ++
        "worktree /src/telar-worktrees/fix\nHEAD def\nbranch refs/heads/fix\n\n" ++
        "worktree /src/telar-worktrees/detached\nHEAD 123\ndetached\n\n";
    var worktrees = listed(porcelain);
    const first = worktrees.next().?;
    try std.testing.expectEqualStrings("/src/telar-worktrees/fix", first.path);
    try std.testing.expectEqualStrings("fix", first.branch);
    try std.testing.expect(worktrees.next() == null);
}
