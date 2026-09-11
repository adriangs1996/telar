//! Workspace command grammar and validated options.

const std = @import("std");
const core = @import("telar-core");
const backend = @import("telar-backend");
const frontend = @import("telar-frontend");
const pty = backend.pty;
const Cursor = @import("cursor_support.zig").Cursor;
const values = @import("values.zig");
const Target = values.Target;
const max_wait_timeout_seconds = values.max_wait_timeout_seconds;
const default_wait_timeout_seconds = values.default_wait_timeout_seconds;
const HookAgent = values.HookAgent;
const parseHookAgent = values.parseHookAgent;
const parseWaitStatus = values.parseWaitStatus;
const parseTimeoutSeconds = values.parseTimeoutSeconds;
const parseLineCount = values.parseLineCount;
const parseTextSource = values.parseTextSource;

pub const max_worktree_branch_bytes = 200;

pub const WorkspaceAction = enum { create };

pub const WorkspaceOptions = @import("WorkspaceOptions.zig");

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
