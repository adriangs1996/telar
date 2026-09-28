const workspace = @import("workspace.zig");
const std = @import("std");
const Cursor = @import("Cursor.zig");
const entity_target = @import("entity_target.zig");
const core = @import("telar-core");
const WorkspaceOptions = @This();

/// The widths `--columns` accepts.
const min_columns = 20;
const max_columns = 1024;

action: workspace.WorkspaceAction,
branch: ?[*:0]const u8 = null,
name: ?[*:0]const u8 = null,
directory: ?[*:0]const u8 = null,
socket: ?[*:0]const u8 = null,
json: bool = false,
target: ?entity_target.Target = null,
/// What the new workspace's first pane runs instead of the login shell.
command: []const [*:0]const u8 = &.{},
/// The first pane's width until a window attaches and sizes it.
columns: ?u16 = null,

pub fn parse(args: []const [*:0]const u8) !WorkspaceOptions {
    if (args.len == 0) {
        return error.MissingWorkspaceAction;
    }

    const action = std.meta.stringToEnum(workspace.WorkspaceAction, std.mem.span(args[0])) orelse return error.UnknownWorkspaceAction;
    var options: WorkspaceOptions = .{ .action = action };
    var index: usize = 1;
    if (action == .get or action == .rename) {
        if (args.len < 2) {
            return error.MissingWorkspaceTarget;
        }

        options.target = try entity_target.Target.parse(std.mem.span(args[1]));
        index = 2;
    }

    if (action == .rename) {
        if (args.len < 3) {
            return error.MissingWorkspaceName;
        }

        const name = std.mem.span(args[2]);
        if (name.len == 0 or name.len > core.max_workspace_name_bytes or !std.unicode.utf8ValidateSlice(name)) {
            return error.InvalidWorkspaceName;
        }

        options.name = args[2];
        index = 3;
    }

    var cursor: Cursor = .{ .remaining = args[index..] };
    while (cursor.next()) |argument| {
        const arg = std.mem.span(argument);
        if (std.mem.eql(u8, arg, "--") and action == .create) {
            options.command = cursor.remaining;
            if (options.command.len == 0) {
                return error.MissingWorkspaceCommand;
            }

            break;
        } else if (std.mem.eql(u8, arg, "--columns") and action == .create) {
            const value = try cursor.require(error.MissingWorkspaceColumns);
            const columns = std.fmt.parseUnsigned(u16, std.mem.span(value), 10) catch return error.InvalidWorkspaceColumns;
            if (columns < min_columns or columns > max_columns) {
                return error.InvalidWorkspaceColumns;
            }

            options.columns = columns;
        } else if (std.mem.eql(u8, arg, "--worktree") and action == .create) {
            const value = try cursor.require(error.MissingWorktreeBranch);
            if (options.branch != null) {
                return error.DuplicateWorktreeOption;
            }

            try workspace.validateWorktreeBranch(std.mem.span(value));
            options.branch = value;
        } else if (std.mem.eql(u8, arg, "--name") and action == .create) {
            const value = try cursor.require(error.MissingWorkspaceName);
            if (options.name != null) {
                return error.DuplicateNameOption;
            }

            options.name = value;
        } else if (std.mem.eql(u8, arg, "--directory") and action == .create) {
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

    if (action == .create and options.branch == null and options.directory == null) {
        return error.MissingWorktreeBranch;
    }

    // A worktree workspace runs `telar worktree create`, which takes its
    // command there.
    if (options.branch != null and (options.command.len != 0 or options.columns != null)) {
        return error.UnknownWorkspaceOption;
    }

    if (options.directory) |directory| {
        if (std.mem.span(directory).len == 0) {
            return error.EmptyWorkspaceDirectory;
        }
    }

    return options;
}

test "workspace list rejects creation options" {
    const options = try WorkspaceOptions.parse(&.{ "list", "--json" });
    try std.testing.expectEqual(workspace.WorkspaceAction.list, options.action);
    try std.testing.expectError(error.UnknownWorkspaceOption, WorkspaceOptions.parse(&.{ "list", "--worktree", "branch" }));
}

test "workspace creation takes a command and a width for its first pane" {
    const options = try WorkspaceOptions.parse(&.{ "create", "--directory", "/home/dev", "--columns", "1024", "--", "codex", "login", "--device-auth" });
    try std.testing.expectEqual(@as(?u16, 1024), options.columns);
    try std.testing.expectEqual(@as(usize, 3), options.command.len);
    try std.testing.expectEqualStrings("--device-auth", std.mem.span(options.command[2]));

    try std.testing.expectError(error.MissingWorkspaceCommand, WorkspaceOptions.parse(&.{ "create", "--directory", "/home/dev", "--" }));
    try std.testing.expectError(error.InvalidWorkspaceColumns, WorkspaceOptions.parse(&.{ "create", "--directory", "/home/dev", "--columns", "5000" }));
    try std.testing.expectError(error.UnknownWorkspaceOption, WorkspaceOptions.parse(&.{ "create", "--worktree", "fix", "--", "claude" }));
}

test "workspace creation supports an existing directory without a worktree" {
    const options = try WorkspaceOptions.parse(&.{ "create", "--directory", "/tmp/project", "--name", "project" });
    try std.testing.expect(options.branch == null);
    try std.testing.expectEqualStrings("/tmp/project", std.mem.span(options.directory.?));
    try std.testing.expectError(error.EmptyWorkspaceDirectory, WorkspaceOptions.parse(&.{ "create", "--directory", "" }));
}
