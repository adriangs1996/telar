//! Where a working tree stands: the branch its HEAD names and whether
//! `git status` reports changes. Reads files and runs bounded `git`
//! children, so callers run it on a worker.
const std = @import("std");
const Status = @import("Status.zig");
const gitfile = @import("gitfile.zig");
const untrusted_git = @import("untrusted_git.zig");

const max_status_bytes = 64 * 1024;

const status_timeout: std.Io.Timeout = .{
    .duration = .{ .clock = .awake, .raw = .fromSeconds(2) },
};

/// Probes the working tree at `workspace_path`, or null when it is not a
/// repository. Git gets `environ` with every repository-chosen program
/// turned off. The branch borrows `buffer`.
///
/// ```zig
/// var buffer: [4096]u8 = undefined;
/// const status = probe.run(io, environ, path, &buffer) orelse return;
/// ```
pub fn run(io: std.Io, environ: std.process.Environ, workspace_path: []const u8, buffer: []u8) ?Status {
    const head = readHead(io, workspace_path, buffer) orelse return null;
    return .{
        .branch = parseHead(head),
        .dirty = statusDirty(io, environ, workspace_path),
    };
}

fn readHead(io: std.Io, workspace_path: []const u8, buffer: []u8) ?[]const u8 {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const head_path = std.fmt.bufPrint(&path_buffer, "{s}/.git/HEAD", .{workspace_path}) catch return null;
    if (gitfile.readRegular(io, head_path, buffer)) |bytes| {
        return bytes;
    }

    // A linked worktree keeps `.git` as a file pointing at its real git dir.
    const dot_git_path = std.fmt.bufPrint(&path_buffer, "{s}/.git", .{workspace_path}) catch return null;
    var git_dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const git_dir = gitfile.gitDir(io, dot_git_path, &git_dir_buffer) orelse return null;
    const linked_head = std.fmt.bufPrint(&path_buffer, "{s}/HEAD", .{git_dir}) catch return null;
    return gitfile.readRegular(io, linked_head, buffer);
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

fn statusDirty(io: std.Io, environ: std.process.Environ, workspace_path: []const u8) bool {
    const output = untrusted_git.run(io, .{
        .environ = environ,
        .path = workspace_path,
        .arguments = &.{ "status", "--porcelain", "--no-renames", "--ignore-submodules=all" },
        .timeout = status_timeout,
        .stdout_limit = max_status_bytes,
    }) orelse return false;
    defer output.deinit();
    return output.line().len != 0;
}

test "HEAD contents resolve to a branch or a short detached hash" {
    try std.testing.expectEqualStrings("main", parseHead("ref: refs/heads/main\n"));
    try std.testing.expectEqualStrings("feature/x", parseHead("ref: refs/heads/feature/x"));
    try std.testing.expectEqualStrings("refs/tags/v1", parseHead("ref: refs/tags/v1\n"));
    try std.testing.expectEqualStrings("0a1b2c3d", parseHead("0a1b2c3d4e5f60718293a4b5c6d7e8f901234567\n"));
}
