//! Where a working tree stands: the branch its HEAD names and whether
//! `git status` reports changes. Reads files and runs bounded `git`
//! children, so callers run it on a worker.
const std = @import("std");
const Status = @import("Status.zig");
const gitfile = @import("gitfile.zig");
const untrusted_git = @import("untrusted_git.zig");

/// How long `git status` may take, config read included. A large
/// monorepo on a cold cache takes seconds; the probe runs on a worker.
pub const status_timeout_ms = 10 * std.time.ms_per_s;

const status_timeout: std.Io.Timeout = .{
    .duration = .{
        .clock = .awake,
        .raw = .fromMilliseconds(status_timeout_ms),
    },
};

/// Bytes of `git status --porcelain` kept: only whether it printed matters,
/// so the rest is read and dropped, never a failure.
const kept_status_bytes = 256;

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
    const dirty = statusDirty(io, environ, workspace_path);
    return .{
        .branch = parseHead(head),
        .dirty = dirty catch null,
        .timed_out = dirty == error.GitTimedOut,
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

/// An error when Git failed or ran out of time; a failure is no evidence
/// the tree is clean. Any output at all means changes, however long.
fn statusDirty(io: std.Io, environ: std.process.Environ, workspace_path: []const u8) untrusted_git.RunError!bool {
    const output = try untrusted_git.run(io, .{
        .environ = environ,
        .path = workspace_path,
        .arguments = &.{ "status", "--porcelain", "--no-renames", "--ignore-submodules=all" },
        .timeout = status_timeout,
        .stdout = .{
            .keep_tail = kept_status_bytes,
        },
    });
    defer output.deinit();
    return output.printed();
}

test "HEAD contents resolve to a branch or a short detached hash" {
    try std.testing.expectEqualStrings("main", parseHead("ref: refs/heads/main\n"));
    try std.testing.expectEqualStrings("feature/x", parseHead("ref: refs/heads/feature/x"));
    try std.testing.expectEqualStrings("refs/tags/v1", parseHead("ref: refs/tags/v1\n"));
    try std.testing.expectEqualStrings("0a1b2c3d", parseHead("0a1b2c3d4e5f60718293a4b5c6d7e8f901234567\n"));
}

test "a status longer than any buffer still reads as dirty" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try temp.dir.realPath(io, &root_buffer)];
    const init = std.process.run(std.testing.allocator, io, .{ .argv = &.{ "git", "init", "-q", "-b", "main", root } }) catch return error.SkipZigTest;
    std.testing.allocator.free(init.stdout);
    std.testing.allocator.free(init.stderr);

    // About 3000 untracked paths print more than the 64 KiB a status once
    // had to fit whole.
    var name_buffer: [64]u8 = undefined;
    for (0..3000) |index| {
        const name = try std.fmt.bufPrint(&name_buffer, "untracked-file-with-a-long-name-{d}.txt", .{index});
        try temp.dir.writeFile(
            io,
            .{
                .sub_path = name,
                .data = "",
            },
        );
    }

    var head: [256]u8 = undefined;
    const status = run(io, std.testing.environ, root, &head).?;
    try std.testing.expectEqualStrings("main", status.branch);
    try std.testing.expect(status.dirty.?);
    try std.testing.expect(!status.timed_out);
}
