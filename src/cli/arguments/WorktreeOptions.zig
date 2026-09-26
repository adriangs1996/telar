const std = @import("std");
const core = @import("telar-core");
const Cursor = @import("Cursor.zig");
const values = @import("values.zig");
const workspace_grammar = @import("workspace.zig");
const WorktreeOptions = @This();

/// Most arguments a command after `--` may carry.
pub const max_command_arguments = 32;
pub const default_wait_seconds = 600;

pub const Action = enum { create, exec, list, open, diff, remove };

action: Action,
branch: ?[*:0]const u8 = null,
title: ?[*:0]const u8 = null,
from: ?[*:0]const u8 = null,
label: ?[*:0]const u8 = null,
/// A workspace id or a directory inside the project.
workspace: ?[*:0]const u8 = null,
/// Overrides the derived checkout directory.
directory: ?[*:0]const u8 = null,
client: u64 = 0,
socket: ?[*:0]const u8 = null,
json: bool = false,
uncommitted: bool = false,
stat: bool = false,
force: bool = false,
delete_branch: bool = false,
/// `exec --wait`: block until the command exits and print its final output.
wait: bool = false,
timeout_seconds: u32 = default_wait_seconds,
command: [max_command_arguments][*:0]const u8 = undefined,
command_len: usize = 0,

/// Parses `telar worktree ACTION [BRANCH] [options] [-- ARGV...]`.
///
/// ```zig
/// const options = try WorktreeOptions.parse(&.{ "create", "fix", "--title", "Fix tabs", "--", "claude", "fix it" });
/// ```
pub fn parse(args: []const [*:0]const u8) !WorktreeOptions {
    if (args.len == 0) {
        return error.MissingWorktreeAction;
    }

    const action = std.meta.stringToEnum(Action, std.mem.span(args[0])) orelse return error.UnknownWorktreeAction;
    var options: WorktreeOptions = .{ .action = action };
    var index: usize = 1;
    if (action != .list) {
        if (args.len < 2 or std.mem.startsWith(u8, std.mem.span(args[1]), "-")) {
            return error.MissingWorktreeBranch;
        }

        try workspace_grammar.validateWorktreeBranch(std.mem.span(args[1]));
        options.branch = args[1];
        index = 2;
    }

    var cursor: Cursor = .{ .remaining = args[index..] };
    while (cursor.next()) |argument| {
        const arg = std.mem.span(argument);
        if (std.mem.eql(u8, arg, "--")) {
            try options.takeCommand(cursor.remaining);
            break;
        } else if (std.mem.eql(u8, arg, "--title") and action == .create) {
            options.title = try single(options.title, try cursor.require(error.MissingWorktreeTitle));
            try validateText(std.mem.span(options.title.?), core.max_worktree_title_bytes);
        } else if (std.mem.eql(u8, arg, "--from") and action == .create) {
            options.from = try single(options.from, try cursor.require(error.MissingWorktreeBase));
            try workspace_grammar.validateWorktreeBranch(std.mem.span(options.from.?));
        } else if (std.mem.eql(u8, arg, "--directory") and action == .create) {
            options.directory = try single(options.directory, try cursor.require(error.MissingWorktreeDirectory));
            if (!std.fs.path.isAbsolute(std.mem.span(options.directory.?))) {
                return error.RelativeWorktreeDirectory;
            }
        } else if (std.mem.eql(u8, arg, "--label") and (action == .create or action == .exec)) {
            options.label = try single(options.label, try cursor.require(error.MissingTabLabel));
            try validateText(std.mem.span(options.label.?), core.max_tab_label_bytes);
        } else if (std.mem.eql(u8, arg, "--workspace") and (action == .create or action == .list)) {
            options.workspace = try single(options.workspace, try cursor.require(error.MissingWorkspaceTarget));
        } else if (std.mem.eql(u8, arg, "--client") and action == .open) {
            const value = std.mem.span(try cursor.require(error.MissingClientId));
            options.client = std.fmt.parseUnsigned(u64, value, 10) catch return error.InvalidClientId;
            if (options.client == 0) {
                return error.InvalidClientId;
            }
        } else if (std.mem.eql(u8, arg, "--uncommitted") and action == .diff) {
            options.uncommitted = true;
        } else if (std.mem.eql(u8, arg, "--stat") and action == .diff) {
            options.stat = true;
        } else if (std.mem.eql(u8, arg, "--force") and action == .remove) {
            options.force = true;
        } else if (std.mem.eql(u8, arg, "--delete-branch") and action == .remove) {
            options.delete_branch = true;
        } else if (std.mem.eql(u8, arg, "--wait") and action == .exec) {
            options.wait = true;
        } else if (std.mem.eql(u8, arg, "--timeout") and action == .exec) {
            options.timeout_seconds = try values.parseTimeoutSeconds(std.mem.span(try cursor.require(error.MissingTimeout)));
        } else if (std.mem.eql(u8, arg, "--json")) {
            options.json = true;
        } else if (std.mem.eql(u8, arg, "--socket")) {
            options.socket = try single(options.socket, try cursor.require(error.MissingSocketPath));
        } else {
            return error.UnknownWorktreeOption;
        }
    }

    if (action == .exec and options.command_len == 0) {
        return error.MissingWorktreeCommand;
    }

    if (action == .create and options.command_len != 0 and options.title == null) {
        return error.MissingWorktreeTitle;
    }

    return options;
}

/// The command after `--`, as argv slices.
/// Example: `const argv = options.argv(&storage);`.
pub fn argv(self: *const WorktreeOptions, storage: *[max_command_arguments][]const u8) []const []const u8 {
    for (self.command[0..self.command_len], 0..) |argument, index| {
        storage[index] = std.mem.span(argument);
    }

    return storage[0..self.command_len];
}

fn takeCommand(self: *WorktreeOptions, remaining: []const [*:0]const u8) !void {
    if (!(self.action == .create or self.action == .exec)) {
        return error.UnexpectedWorktreeCommand;
    }

    if (remaining.len == 0) {
        return error.MissingWorktreeCommand;
    }

    if (remaining.len > max_command_arguments) {
        return error.TooManyCommandArguments;
    }

    for (remaining, 0..) |argument, index| {
        self.command[index] = argument;
    }

    self.command_len = remaining.len;
}

fn single(current: ?[*:0]const u8, value: [*:0]const u8) ![*:0]const u8 {
    if (current != null) {
        return error.DuplicateWorktreeOption;
    }

    return value;
}

fn validateText(text: []const u8, maximum: usize) !void {
    if (text.len == 0 or text.len > maximum or !std.unicode.utf8ValidateSlice(text)) {
        return error.InvalidWorktreeText;
    }

    for (text) |byte| {
        if (byte < 0x20 or byte == 0x7f) {
            return error.InvalidWorktreeText;
        }
    }
}

test "create takes a title and a command after the separator" {
    const options = try WorktreeOptions.parse(&.{ "create", "fix/tabs", "--title", "Fix tabs", "--from", "main", "--", "claude", "--flag-for-claude", "fix it" });
    try std.testing.expectEqual(Action.create, options.action);
    try std.testing.expectEqualStrings("fix/tabs", std.mem.span(options.branch.?));
    try std.testing.expectEqualStrings("Fix tabs", std.mem.span(options.title.?));

    var storage: [max_command_arguments][]const u8 = undefined;
    const command = options.argv(&storage);
    try std.testing.expectEqual(@as(usize, 3), command.len);
    try std.testing.expectEqualStrings("--flag-for-claude", command[1]);
}

test "a command needs a title on create and is required by exec" {
    try std.testing.expectError(error.MissingWorktreeTitle, WorktreeOptions.parse(&.{ "create", "fix", "--", "claude" }));
    try std.testing.expectError(error.MissingWorktreeCommand, WorktreeOptions.parse(&.{ "exec", "fix" }));
    try std.testing.expectError(error.UnexpectedWorktreeCommand, WorktreeOptions.parse(&.{ "list", "--", "ls" }));
    _ = try WorktreeOptions.parse(&.{ "create", "fix" });
}

test "branches that look like options or escape a ref are refused" {
    try std.testing.expectError(error.MissingWorktreeBranch, WorktreeOptions.parse(&.{ "exec", "--title" }));
    try std.testing.expectError(error.InvalidWorktreeBranch, WorktreeOptions.parse(&.{ "diff", "a..b" }));
    try std.testing.expectError(error.UnknownWorktreeOption, WorktreeOptions.parse(&.{ "diff", "fix", "--force" }));
    try std.testing.expectError(error.RelativeWorktreeDirectory, WorktreeOptions.parse(&.{ "create", "fix", "--directory", "rel" }));
    const removal = try WorktreeOptions.parse(&.{ "remove", "fix", "--force", "--delete-branch" });
    try std.testing.expect(removal.force and removal.delete_branch);
}
