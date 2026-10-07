//! Finds the Git linked worktree a directory lies in by reading files only:
//! the first `.git` above the directory is a file (`gitdir: ...`) in a linked
//! worktree and a directory in a main checkout. Cheap enough for a hook.
const std = @import("std");
const Linked = @import("Linked.zig");
const gitfile = @import("gitfile.zig");
const probe = @import("probe.zig");

const max_depth = 64;

/// Returns the linked worktree containing `path`, or null for a main
/// checkout, a bare path outside any repository or an unreadable tree.
///
/// ```zig
/// var root: [std.fs.max_path_bytes]u8 = undefined;
/// var head: [256]u8 = undefined;
/// const linked = gitstatus.linked_worktree.find(io, cwd, &root, &head) orelse return;
/// ```
pub fn find(io: std.Io, path: []const u8, root_buffer: []u8, head_buffer: []u8) ?Linked {
    if (path.len == 0 or path.len > root_buffer.len or !std.fs.path.isAbsolute(path)) {
        return null;
    }

    var current = path;
    var depth: usize = 0;
    while (depth < max_depth) : (depth += 1) {
        var dot_git: [std.fs.max_path_bytes]u8 = undefined;
        const candidate = std.fmt.bufPrint(&dot_git, "{s}/.git", .{std.mem.trimEnd(u8, current, "/")}) catch return null;
        if (std.Io.Dir.cwd().statFile(io, candidate, .{})) |stat| {
            if (stat.kind == .directory) {
                return null;
            }

            const branch = linkedBranch(io, candidate, head_buffer) orelse return null;
            @memcpy(root_buffer[0..current.len], current);
            return .{ .root = root_buffer[0..current.len], .branch = branch };
        } else |_| {}

        const parent = std.fs.path.dirname(current) orelse return null;
        if (parent.len == current.len) {
            return null;
        }

        current = parent;
    }

    return null;
}

/// Reads the HEAD of the git dir a `.git` file points at, when that git dir
/// belongs to a linked worktree (it has a `commondir` file).
fn linkedBranch(io: std.Io, dot_git_path: []const u8, head_buffer: []u8) ?[]const u8 {
    var git_dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const git_dir = gitfile.gitDir(io, dot_git_path, &git_dir_buffer) orelse return null;
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const common_path = std.fmt.bufPrint(&path_buffer, "{s}/commondir", .{git_dir}) catch return null;
    var common_buffer: [std.fs.max_path_bytes]u8 = undefined;
    _ = gitfile.readRegular(io, common_path, &common_buffer) orelse return null;

    const head_path = std.fmt.bufPrint(&path_buffer, "{s}/HEAD", .{git_dir}) catch return null;
    const head = gitfile.readRegular(io, head_path, head_buffer) orelse return null;
    const branch = probe.parseHead(head);
    return if (branch.len == 0) null else branch;
}

/// The branch the repository's main checkout stands on, read from the
/// linked worktree at `root`: its `.git` file names its git dir, whose
/// `commondir` names the repository's, whose `HEAD` is the main checkout's.
/// Null for a main checkout, a detached main HEAD or an unreadable tree.
///
/// ```zig
/// var head: [256]u8 = undefined;
/// const base = gitstatus.linked_worktree.mainBranch(io, "/src/telar-worktrees/fix", &head) orelse return;
/// ```
pub fn mainBranch(io: std.Io, root: []const u8, head_buffer: []u8) ?[]const u8 {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dot_git_path = std.fmt.bufPrint(&path_buffer, "{s}/.git", .{std.mem.trimEnd(u8, root, "/")}) catch return null;
    var git_dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const git_dir = gitfile.gitDir(io, dot_git_path, &git_dir_buffer) orelse return null;

    const common_path = std.fmt.bufPrint(&path_buffer, "{s}/commondir", .{git_dir}) catch return null;
    var common_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const named_common = std.mem.trim(u8, gitfile.readRegular(io, common_path, &common_buffer) orelse return null, " \t\r\n");
    var common_dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const common = gitfile.resolve(git_dir, named_common, &common_dir_buffer) orelse return null;

    const head_path = std.fmt.bufPrint(&path_buffer, "{s}/HEAD", .{common}) catch return null;
    const head = std.mem.trim(u8, gitfile.readRegular(io, head_path, head_buffer) orelse return null, " \r\n");
    const prefix = "ref: refs/heads/";
    if (!std.mem.startsWith(u8, head, prefix) or head.len == prefix.len) {
        return null;
    }

    return head[prefix.len..];
}
