const workspace = @import("workspace.zig");
const std = @import("std");
const Cursor = @import("Cursor.zig");
const WorkspaceOptions = @This();

action: workspace.WorkspaceAction,
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

            try workspace.validateWorktreeBranch(std.mem.span(value));
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
