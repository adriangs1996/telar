//! Git as the CLI runs it for worktrees: the main checkout of a repository,
//! the branch it stands on, adding and removing linked worktrees and deleting
//! branches. Git runs in the CLI process with the user's environment and
//! credentials; the runtime never runs Git on a client's behalf. The one
//! check that lets a deletion go ahead without a person, `branchMerged`, runs
//! Git as `gitstatus.untrusted_git` does. Branch names are validated before
//! they reach an argv and always sit after `--` or in a position Git never
//! parses as an option.

const std = @import("std");
const gitstatus = @import("gitstatus");
const workspace = @import("arguments/workspace.zig");
const WorktreeCheckout = @import("WorktreeCheckout.zig");
const DiffRequest = @import("DiffRequest.zig");
const ListedWorktrees = @import("ListedWorktrees.zig");
const GitTransfer = @import("GitTransfer.zig");
const repository_identity = @import("repository_identity.zig");

const git_timeout: std.Io.Timeout = .{
    .duration = .{ .clock = .awake, .raw = .fromSeconds(60) },
};

/// A push or fetch crosses the network and may carry a whole history.
const transfer_timeout: std.Io.Timeout = .{
    .duration = .{ .clock = .awake, .raw = .fromSeconds(600) },
};

const max_git_output_bytes = 64 * 1024;

/// Longest commit hash Git prints: SHA-256 in hex.
pub const max_commit_bytes = 64;
/// Longest `origin` URL read to derive a repository identity.
const max_origin_url_bytes = 2048;

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

/// Whether `git branch -d` would delete `branch` from the repository at
/// `root`: every commit of it is in its upstream, or in `HEAD` when it has
/// none. Nobody confirms a deletion this allows, so Git runs as
/// `gitstatus.untrusted_git` runs it and the repository's config cannot run
/// a program on the way. False when Git fails, so a doubt asks a person.
///
/// ```zig
/// const unattended = worktree_git.branchMerged(init.io, init.minimal.environ, root, "fix");
/// ```
pub fn branchMerged(io: std.Io, environ: std.process.Environ, root: []const u8, branch: []const u8) bool {
    workspace.validateWorktreeBranch(branch) catch return false;
    var upstream_buffer: [workspace.max_worktree_branch_bytes + 16]u8 = undefined;
    const upstream = std.fmt.bufPrint(&upstream_buffer, "{s}@{{upstream}}", .{branch}) catch return false;
    var ref_buffer: [workspace.max_worktree_branch_bytes + 16]u8 = undefined;
    const ref = std.fmt.bufPrint(&ref_buffer, "refs/heads/{s}", .{branch}) catch return false;

    const repository: gitstatus.Checkout = .{
        .environ = environ,
        .path = root,
    };
    var commit_buffer: [max_commit_bytes]u8 = undefined;
    const reference = hardenedLine(io, repository, &.{ "rev-parse", "--verify", "--quiet", "--end-of-options", upstream }, &commit_buffer) orelse "HEAD";
    return hardenedLine(io, repository, &.{ "merge-base", "--is-ancestor", ref, reference }, &commit_buffer) != null;
}

/// Whether the checkout has uncommitted changes or untracked files.
///
/// ```zig
/// if (try worktree_git.hasChanges(init, directory)) return error.WorktreeHasChanges;
/// ```
pub fn hasChanges(init: std.process.Init, directory: []const u8) !bool {
    return try changedFiles(init, directory) != 0;
}

/// How many files in the checkout are modified, staged or untracked.
///
/// ```zig
/// const left = try worktree_git.changedFiles(init, root);
/// ```
pub fn changedFiles(init: std.process.Init, directory: []const u8) !usize {
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

    var lines = std.mem.tokenizeScalar(u8, result.stdout, '\n');
    var count: usize = 0;
    while (lines.next()) |_| {
        count += 1;
    }

    return count;
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

/// The repository identity of the clone at `root`, from its `origin`.
///
/// ```zig
/// const identity = try worktree_git.originIdentity(init, root, &buffer);
/// // "github.com/o/telar"
/// ```
pub fn originIdentity(init: std.process.Init, root: []const u8, buffer: []u8) ![]const u8 {
    var url_buffer: [max_origin_url_bytes]u8 = undefined;
    const url = gitLine(init, &.{ "git", "-C", root, "config", "--get", "remote.origin.url" }, &url_buffer) catch return error.NoOriginRemote;
    return repository_identity.normalize(url, buffer);
}

/// The commit a revision names, as a full hash.
///
/// ```zig
/// const commit = try worktree_git.commitOf(init, root, "HEAD", &buffer);
/// ```
pub fn commitOf(init: std.process.Init, root: []const u8, revision: []const u8, buffer: []u8) ![]const u8 {
    var spec_buffer: [workspace.max_worktree_branch_bytes + 16]u8 = undefined;
    const spec = std.fmt.bufPrint(&spec_buffer, "{s}^{{commit}}", .{revision}) catch return error.InvalidWorktreeBranch;
    return gitLine(init, &.{ "git", "-C", root, "rev-parse", "--verify", "--quiet", "--end-of-options", spec }, buffer) catch error.UnknownRevision;
}

/// Sends one ref to another machine's clone. Never forced, so Git refuses a
/// branch that exists there with other history.
///
/// ```zig
/// try worktree_git.push(init, .{ .root = root, .url = url, .refspec = "abc:refs/heads/fix", .environ_map = &map });
/// ```
pub fn push(init: std.process.Init, transfer: GitTransfer) !void {
    return transferRun(init, &.{ "git", "-C", transfer.root, "push", "--quiet", "--", transfer.url, transfer.refspec }, transfer.environ_map, error.GitPushFailed);
}

/// Fetches one ref from another machine's clone into this clone.
///
/// ```zig
/// try worktree_git.fetch(init, .{ .root = root, .url = url, .refspec = "+refs/heads/fix:refs/remotes/box/fix", .environ_map = &map });
/// ```
pub fn fetch(init: std.process.Init, transfer: GitTransfer) !void {
    return transferRun(init, &.{ "git", "-C", transfer.root, "fetch", "--quiet", "--no-tags", "--", transfer.url, transfer.refspec }, transfer.environ_map, error.GitFetchFailed);
}

pub fn branchExists(init: std.process.Init, root: []const u8, branch: []const u8) bool {
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

fn transferRun(init: std.process.Init, argv: []const []const u8, environ_map: *const std.process.Environ.Map, failure: anyerror) !void {
    const result = std.process.run(init.gpa, init.io, .{
        .argv = argv,
        .stdout_limit = .limited(max_git_output_bytes),
        .stderr_limit = .limited(max_git_output_bytes),
        .timeout = transfer_timeout,
        .environ_map = environ_map,
    }) catch return failure;
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("{s}", .{result.stderr});
        return failure;
    }
}

// One read-only Git command run as `gitstatus.untrusted_git` runs it: what
// it printed, or null when it failed or printed more than `buffer` holds.
fn hardenedLine(io: std.Io, repository: gitstatus.Checkout, arguments: []const []const u8, buffer: []u8) ?[]const u8 {
    const output = gitstatus.untrusted_git.run(io, .{
        .environ = repository.environ,
        .path = repository.path,
        .arguments = arguments,
        .timeout = git_timeout,
        .stdout_limit = max_git_output_bytes,
    }) orelse return null;
    defer output.deinit();

    const line = output.line();
    if (line.len > buffer.len) {
        return null;
    }

    @memcpy(buffer[0..line.len], line);
    return buffer[0..line.len];
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

fn testGit(argv: []const []const u8) !void {
    const result = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = argv });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        return error.GitFailed;
    }
}

fn testCommit(root: []const u8, message: []const u8) !void {
    try testGit(&.{ "git", "-C", root, "-c", "user.name=telar", "-c", "user.email=telar@localhost", "-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty", "-m", message });
}

test "a branch counts as merged exactly when git branch -d deletes it" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try temp.dir.realPath(io, &root_buffer)];
    testGit(&.{ "git", "init", "-q", "-b", "main", root }) catch return error.SkipZigTest;
    try testCommit(root, "one");
    try testGit(&.{ "git", "-C", root, "branch", "old" });
    try testCommit(root, "two");

    // In HEAD and without an upstream.
    try testGit(&.{ "git", "-C", root, "branch", "landed" });
    // In HEAD, but not in the upstream Git compares it with.
    try testGit(&.{ "git", "-C", root, "branch", "behind" });
    try testGit(&.{ "git", "-C", root, "branch", "--set-upstream-to=old", "behind" });
    // One commit past HEAD.
    try testGit(&.{ "git", "-C", root, "checkout", "-q", "-b", "ahead" });
    try testCommit(root, "three");
    // Past HEAD, but in its upstream.
    try testGit(&.{ "git", "-C", root, "branch", "--track", "released", "ahead" });
    try testGit(&.{ "git", "-C", root, "checkout", "-q", "main" });

    const cases = [_]struct { branch: []const u8, merged: bool }{
        .{ .branch = "landed", .merged = true },
        .{ .branch = "behind", .merged = false },
        .{ .branch = "ahead", .merged = false },
        .{ .branch = "released", .merged = true },
        .{ .branch = "missing", .merged = false },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.merged, branchMerged(io, std.testing.environ, root, case.branch));
    }

    for (cases) |case| {
        const deleted = if (testGit(&.{ "git", "-C", root, "branch", "-d", "--", case.branch })) true else |_| false;
        try std.testing.expectEqual(case.merged, deleted);
    }
}
