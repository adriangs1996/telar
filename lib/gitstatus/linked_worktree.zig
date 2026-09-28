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

test "a relative gitdir resolves against the worktree, not the reader's directory" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    // `git worktree add` with worktree.useRelativePaths writes these.
    try temp.dir.createDirPath(io, "main/.git/worktrees/fix");
    try temp.dir.createDirPath(io, "fix/src");
    try temp.dir.writeFile(io, .{ .sub_path = "main/.git/HEAD", .data = "ref: refs/heads/trunk\n" });
    try temp.dir.writeFile(io, .{ .sub_path = "main/.git/worktrees/fix/HEAD", .data = "ref: refs/heads/fix\n" });
    try temp.dir.writeFile(io, .{ .sub_path = "main/.git/worktrees/fix/commondir", .data = "../..\n" });
    try temp.dir.writeFile(io, .{ .sub_path = "fix/.git", .data = "gitdir: ../main/.git/worktrees/fix\n" });

    var base_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buffer[0..try temp.dir.realPath(io, &base_buffer)];
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const nested = try std.fmt.bufPrint(&path_buffer, "{s}/fix/src", .{base});
    var root: [std.fs.max_path_bytes]u8 = undefined;
    var head: [256]u8 = undefined;
    const linked = find(io, nested, &root, &head).?;
    try std.testing.expectEqualStrings("fix", linked.branch);

    var main_head: [256]u8 = undefined;
    try std.testing.expectEqualStrings("trunk", mainBranch(io, linked.root, &main_head).?);
}

test "a FIFO where Git keeps a file is refused instead of blocking the reader" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var base_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buffer[0..try temp.dir.realPath(io, &base_buffer)];

    try temp.dir.createDirPath(io, "main/.git/worktrees/fix");
    try temp.dir.createDirPath(io, "fix");
    try temp.dir.createDirPath(io, "pipe");
    try temp.dir.writeFile(io, .{ .sub_path = "main/.git/worktrees/fix/commondir", .data = "../..\n" });
    var gitfile_buffer: [std.fs.max_path_bytes + 32]u8 = undefined;
    const dot_git = try std.fmt.bufPrint(&gitfile_buffer, "gitdir: {s}/main/.git/worktrees/fix\n", .{base});
    try temp.dir.writeFile(io, .{ .sub_path = "fix/.git", .data = dot_git });

    var fifo_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const fifos = [_][]const u8{ "pipe/.git", "main/.git/worktrees/fix/HEAD", "main/.git/HEAD" };
    for (fifos) |fifo| {
        const path = try std.fmt.bufPrint(&fifo_buffer, "{s}/{s}", .{ base, fifo });
        if (!gitfile.makeTestingFifo(path)) {
            return error.SkipZigTest;
        }
    }

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var root: [std.fs.max_path_bytes]u8 = undefined;
    var head: [256]u8 = undefined;
    try std.testing.expect(find(io, try std.fmt.bufPrint(&path_buffer, "{s}/pipe", .{base}), &root, &head) == null);

    const fix = try std.fmt.bufPrint(&path_buffer, "{s}/fix", .{base});
    try std.testing.expect(find(io, fix, &root, &head) == null);
    try std.testing.expect(mainBranch(io, fix, &head) == null);
}

test "a linked worktree is found from a nested directory and a main checkout is not" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    try temp.dir.createDirPath(io, "main/.git/worktrees/fix");
    try temp.dir.createDirPath(io, "fix/src/deep");
    try temp.dir.writeFile(io, .{ .sub_path = "main/.git/worktrees/fix/HEAD", .data = "ref: refs/heads/fix/tabs\n" });
    try temp.dir.writeFile(io, .{ .sub_path = "main/.git/worktrees/fix/commondir", .data = "../..\n" });

    var base_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buffer[0..try temp.dir.realPath(io, &base_buffer)];
    var gitfile_buffer: [std.fs.max_path_bytes + 32]u8 = undefined;
    const dot_git = try std.fmt.bufPrint(&gitfile_buffer, "gitdir: {s}/main/.git/worktrees/fix\n", .{base});
    try temp.dir.writeFile(io, .{ .sub_path = "fix/.git", .data = dot_git });

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var root: [std.fs.max_path_bytes]u8 = undefined;
    var head: [256]u8 = undefined;
    const nested = try std.fmt.bufPrint(&path_buffer, "{s}/fix/src/deep", .{base});
    const linked = find(io, nested, &root, &head).?;
    try std.testing.expect(std.mem.endsWith(u8, linked.root, "/fix"));
    try std.testing.expectEqualStrings("fix/tabs", linked.branch);

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main = try std.fmt.bufPrint(&main_buffer, "{s}/main", .{base});
    try std.testing.expect(find(io, main, &root, &head) == null);
    try std.testing.expect(find(io, "relative/path", &root, &head) == null);

    try temp.dir.writeFile(io, .{ .sub_path = "main/.git/HEAD", .data = "ref: refs/heads/trunk\n" });
    var main_head: [256]u8 = undefined;
    try std.testing.expectEqualStrings("trunk", mainBranch(io, linked.root, &main_head).?);
    try std.testing.expect(mainBranch(io, main, &main_head) == null);

    try temp.dir.writeFile(io, .{ .sub_path = "main/.git/HEAD", .data = "0123456789abcdef0123456789abcdef01234567\n" });
    try std.testing.expect(mainBranch(io, linked.root, &main_head) == null);
}
