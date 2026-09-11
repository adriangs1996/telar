//! Workspace command grammar and validated options.

const std = @import("std");

pub const max_worktree_branch_bytes = 200;

pub const WorkspaceAction = enum { create };

pub fn validateWorktreeBranch(branch: []const u8) !void {
    if (branch.len == 0 or branch.len > max_worktree_branch_bytes) {
        return error.InvalidWorktreeBranch;
    }
    if (branch[0] == '-' or branch[0] == '.') {
        return error.InvalidWorktreeBranch;
    }
    if (std.mem.indexOf(u8, branch, "..") != null) {
        return error.InvalidWorktreeBranch;
    }

    for (branch) |byte| {
        if (byte <= ' ' or byte == 0x7f or byte == '~' or byte == '^' or byte == ':') {
            return error.InvalidWorktreeBranch;
        }
    }
}
