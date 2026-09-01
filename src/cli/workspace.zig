//! The `telar workspace` command family: create workspaces from the CLI,
//! optionally backed by a fresh git worktree.

const std = @import("std");
const core = @import("telar-core");
const agent = @import("agent.zig");
const control = @import("control.zig");
const parser = @import("parser.zig");

const Io = std.Io;
const File = Io.File;
const schema = core.schema;
const WorkspaceOptions = parser.WorkspaceOptions;

const git_timeout: Io.Timeout = .{
    .duration = .{ .clock = .awake, .raw = .fromSeconds(60) },
};

/// Runs one workspace command and returns the process exit code.
///
/// ```zig
/// std.process.exit(try workspace.run(process_init, options));
/// ```
pub fn run(init: std.process.Init, options: WorkspaceOptions) !u8 {
    var output_buffer: [4096]u8 = undefined;
    var output = File.stdout().writerStreaming(init.io, &output_buffer);
    const writer = &output.interface;
    defer writer.flush() catch {};

    return execute(init, options, writer) catch |err| {
        std.debug.print("telar workspace: {s}\n", .{describe(err)});
        return agent.exit_failure;
    };
}

/// Adds the git worktree first, then asks the runtime to create a workspace
/// rooted at it. Git runs in this process with the user's environment and
/// credentials; the runtime never executes git on the CLI's behalf.
fn execute(init: std.process.Init, options: WorkspaceOptions, writer: *Io.Writer) !u8 {
    const branch = std.mem.span(options.branch.?);
    var directory_buffer: [4096]u8 = undefined;
    const directory = try resolveDirectory(init, options, &directory_buffer);
    try addWorktree(init, options, directory);

    var session = try control.Session.open(init, options.socket);
    defer session.close();
    const workspace_id = try session.createWorkspace(.{
        .name = if (options.name) |name| std.mem.span(name) else branch,
        .cwd = directory,
        .arguments = &.{shellArgument(init.minimal.environ)},
    });

    if (options.json) {
        try writer.print("{{\"workspace_id\":{d},\"directory\":", .{workspace_id});
        try control.writeJsonString(writer, directory);
        try writer.writeAll("}\n");
    } else {
        try writer.print("workspace {d} created at {s}\n", .{ workspace_id, directory });
    }

    return agent.exit_ok;
}

fn resolveDirectory(init: std.process.Init, options: WorkspaceOptions, buffer: []u8) ![]const u8 {
    if (options.directory) |directory| {
        return std.mem.span(directory);
    }

    var toplevel_buffer: [4096]u8 = undefined;
    const toplevel = try repositoryRoot(init, &toplevel_buffer);
    return deriveDirectory(toplevel, std.mem.span(options.branch.?), buffer);
}

/// Sibling directory `<parent>/<repo>-worktrees/<branch>` with path
/// separators in the branch name flattened to dashes, so the worktree never
/// lands inside the repository it mirrors.
///
/// ```zig
/// const directory = try deriveDirectory("/src/telar", "fix/tabs", &buffer);
/// ```
fn deriveDirectory(toplevel: []const u8, branch: []const u8, buffer: []u8) ![]const u8 {
    if (branch.len > parser.max_worktree_branch_bytes) {
        return error.InvalidWorktreeBranch;
    }

    var sanitized: [parser.max_worktree_branch_bytes]u8 = undefined;
    for (branch, 0..) |byte, index| {
        sanitized[index] = if (byte == '/' or byte == '\\') '-' else byte;
    }

    const parent = std.fs.path.dirname(toplevel) orelse return error.InvalidRepository;
    const repository = std.fs.path.basename(toplevel);
    if (repository.len == 0) {
        return error.InvalidRepository;
    }

    return std.fmt.bufPrint(buffer, "{s}/{s}-worktrees/{s}", .{ parent, repository, sanitized[0..branch.len] }) catch error.PathTooLong;
}

fn repositoryRoot(init: std.process.Init, buffer: []u8) ![]const u8 {
    const result = std.process.run(init.gpa, init.io, .{
        .argv = &.{ "git", "rev-parse", "--show-toplevel" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
        .timeout = git_timeout,
    }) catch return error.NotARepository;
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        return error.NotARepository;
    }

    const path = std.mem.trim(u8, result.stdout, " \r\n");
    if (path.len == 0 or path.len > buffer.len or !std.fs.path.isAbsolute(path)) {
        return error.NotARepository;
    }

    @memcpy(buffer[0..path.len], path);
    return buffer[0..path.len];
}

/// Checks out the branch into the directory, creating the branch only when
/// it does not exist yet. Branch names were validated at parse time and the
/// argv is built positionally, so git never sees them as options.
fn addWorktree(init: std.process.Init, options: WorkspaceOptions, directory: []const u8) !void {
    const branch = std.mem.span(options.branch.?);
    if (branchExists(init, branch)) {
        try runWorktreeAdd(init, &.{ "git", "worktree", "add", directory, branch });
    } else {
        try runWorktreeAdd(init, &.{ "git", "worktree", "add", "-b", branch, directory });
    }
}

fn branchExists(init: std.process.Init, branch: []const u8) bool {
    var ref_buffer: [parser.max_worktree_branch_bytes + 16]u8 = undefined;
    const ref = std.fmt.bufPrint(&ref_buffer, "refs/heads/{s}", .{branch}) catch return false;

    const result = std.process.run(init.gpa, init.io, .{
        .argv = &.{ "git", "rev-parse", "--verify", "--quiet", ref },
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(256),
        .timeout = git_timeout,
    }) catch return false;
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);

    return result.term == .exited and result.term.exited == 0;
}

fn runWorktreeAdd(init: std.process.Init, argv: []const []const u8) !void {
    const result = std.process.run(init.gpa, init.io, .{
        .argv = argv,
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
        .timeout = git_timeout,
    }) catch return error.WorktreeAddFailed;
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("telar workspace: git worktree add failed:\n{s}", .{result.stderr});
        return error.WorktreeAddFailed;
    }
}

fn shellArgument(environ: std.process.Environ) []const u8 {
    const configured = environ.getPosix("SHELL") orelse return "/bin/sh";
    if (configured.len == 0) {
        return "/bin/sh";
    }

    return configured;
}

fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.NotARepository => "the current directory is not inside a git repository",
        error.InvalidRepository => "could not derive a worktree directory from the repository path",
        error.WorktreeAddFailed => "git worktree add failed",
        error.PathTooLong => "the worktree path exceeds the supported length",
        error.InvalidWorktreeBranch => "the branch name is not usable for a worktree",
        else => control.describe(err),
    };
}

test "worktree directories derive from the repository and branch" {
    var buffer: [512]u8 = undefined;
    const derived = try deriveDirectory("/src/telar", "fix/tabs", &buffer);
    try std.testing.expectEqualStrings("/src/telar-worktrees/fix-tabs", derived);

    try std.testing.expectError(error.InvalidRepository, deriveDirectory("/", "main", &buffer));

    var small: [8]u8 = undefined;
    try std.testing.expectError(error.PathTooLong, deriveDirectory("/src/telar", "main", &small));
}
