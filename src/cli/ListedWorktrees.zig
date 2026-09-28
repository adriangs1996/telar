const std = @import("std");
const ListedWorktree = @import("ListedWorktree.zig");
/// Iterates `git worktree list --porcelain` output, skipping the main
/// checkout and detached or bare entries.
const ListedWorktrees = @This();

lines: std.mem.SplitIterator(u8, .scalar),
first: bool = true,

pub fn next(self: *ListedWorktrees) ?ListedWorktree {
    var path: []const u8 = "";
    var branch: []const u8 = "";
    while (self.lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "worktree ")) {
            path = line["worktree ".len..];
        } else if (std.mem.startsWith(u8, line, "branch refs/heads/")) {
            branch = line["branch refs/heads/".len..];
        } else if (line.len == 0 and path.len != 0) {
            const main = self.first;
            self.first = false;
            if (!main and branch.len != 0) {
                return .{ .path = path, .branch = branch };
            }

            path = "";
            branch = "";
        }
    }

    return null;
}
