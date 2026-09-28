//! Workspace command grammar and validated options.

const std = @import("std");
const core = @import("telar-core");

/// A worktree's branch travels to the runtime whole, so the CLI accepts no
/// longer name than the protocol carries.
pub const max_worktree_branch_bytes = core.max_git_branch_bytes;

pub const WorkspaceAction = enum { create, list, get, rename };

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
    if (!std.unicode.utf8ValidateSlice(branch)) {
        return error.InvalidWorktreeBranch;
    }

    for (branch) |byte| {
        if (byte <= ' ' or byte == 0x7f or byte == '~' or byte == '^' or byte == ':') {
            return error.InvalidWorktreeBranch;
        }
    }
}
