//! Workspace command grammar and validated options.

const std = @import("std");
const core = @import("telar-core");
const backend = @import("telar-backend");
const frontend = @import("telar-frontend");
const pty = backend.pty;
const Cursor = @import("cursor.zig").Cursor;
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

pub const WorkspaceOptions = struct {
    action: WorkspaceAction,
    branch: ?[*:0]const u8 = null,
    name: ?[*:0]const u8 = null,
    directory: ?[*:0]const u8 = null,
    socket: ?[*:0]const u8 = null,
    json: bool = false,

    pub fn parse(args: []const [*:0]const u8) !WorkspaceOptions {
        if (args.len == 0) {
            return error.MissingWorkspaceAction;
        }

        if (!std.mem.eql(u8, std.mem.span(args[0]), "create")) {
            return error.UnknownWorkspaceAction;
        }

        var options: WorkspaceOptions = .{ .action = .create };
        const index: usize = 1;
        var cursor: Cursor = .{ .remaining = args[index..] };
        while (cursor.next()) |argument| {
            const arg = std.mem.span(argument);
            if (std.mem.eql(u8, arg, "--worktree")) {
                const value = try cursor.require(error.MissingWorktreeBranch);
                if (options.branch != null) {
                    return error.DuplicateWorktreeOption;
                }

                try validateWorktreeBranch(std.mem.span(value));
                options.branch = value;
            } else if (std.mem.eql(u8, arg, "--name")) {
                const value = try cursor.require(error.MissingWorkspaceName);
                if (options.name != null) {
                    return error.DuplicateNameOption;
                }

                options.name = value;
            } else if (std.mem.eql(u8, arg, "--directory")) {
                const value = try cursor.require(error.MissingWorktreeDirectory);
                if (options.directory != null) {
                    return error.DuplicateDirectoryOption;
                }

                options.directory = value;
            } else if (std.mem.eql(u8, arg, "--socket")) {
                const value = try cursor.require(error.MissingSocketPath);
                if (options.socket != null) {
                    return error.DuplicateSocketOption;
                }

                options.socket = value;
            } else if (std.mem.eql(u8, arg, "--json")) {
                options.json = true;
            } else {
                return error.UnknownWorkspaceOption;
            }
        }

        if (options.branch == null) {
            return error.MissingWorktreeBranch;
        }

        return options;
    }
};

fn validateWorktreeBranch(branch: []const u8) !void {
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
