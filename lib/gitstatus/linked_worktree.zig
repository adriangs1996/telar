//! Finds the Git linked worktree a directory lies in by reading files only:
//! the first `.git` above the directory is a file (`gitdir: ...`) in a linked
//! worktree and a directory in a main checkout. Cheap enough for a hook.
const std = @import("std");
const Linked = @import("Linked.zig");
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
fn linkedBranch(io: std.Io, gitfile_path: []const u8, head_buffer: []u8) ?[]const u8 {
    var gitfile_buffer: [std.fs.max_path_bytes + 16]u8 = undefined;
    const gitfile = readSmall(io, gitfile_path, &gitfile_buffer) orelse return null;
    const trimmed = std.mem.trim(u8, gitfile, " \r\n");
    if (!std.mem.startsWith(u8, trimmed, "gitdir:")) {
        return null;
    }

    const git_dir = std.mem.trim(u8, trimmed["gitdir:".len..], " ");
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const common_path = std.fmt.bufPrint(&path_buffer, "{s}/commondir", .{git_dir}) catch return null;
    _ = std.Io.Dir.cwd().statFile(io, common_path, .{}) catch return null;

    const head_path = std.fmt.bufPrint(&path_buffer, "{s}/HEAD", .{git_dir}) catch return null;
    const head = readSmall(io, head_path, head_buffer) orelse return null;
    const branch = probe.parseHead(head);
    return if (branch.len == 0) null else branch;
}

fn readSmall(io: std.Io, path: []const u8, buffer: []u8) ?[]const u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    var reader = file.readerStreaming(io, &.{});
    const len = reader.interface.readSliceShort(buffer) catch return null;
    return buffer[0..len];
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
    const gitfile = try std.fmt.bufPrint(&gitfile_buffer, "gitdir: {s}/main/.git/worktrees/fix\n", .{base});
    try temp.dir.writeFile(io, .{ .sub_path = "fix/.git", .data = gitfile });

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
}
