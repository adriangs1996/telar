const std = @import("std");
const core = @import("telar-core");
const Cursor = @import("Cursor.zig");
const values = @import("values.zig");
const workspace_grammar = @import("workspace.zig");
const WorktreeOptions = @This();

/// Most arguments a command after `--` may carry.
pub const max_command_arguments = 32;
pub const default_wait_seconds = 600;
/// Longest repository identity `resolve` accepts, in bytes.
pub const max_repository_bytes = 512;

pub const Action = enum { create, exec, list, open, diff, remove, resolve, fetch };

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
/// `create` and `fetch`: the machine the worktree lives on.
machine: ?[*:0]const u8 = null,
/// `create`: the label of the machine that dispatched it here.
dispatched_from: ?[*:0]const u8 = null,
/// `resolve`: the repository identity to find among the workspaces.
repository: ?[*:0]const u8 = null,
socket: ?[*:0]const u8 = null,
json: bool = false,
setup: bool = false,
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
    if (action != .list and action != .resolve) {
        if (args.len < 2 or std.mem.startsWith(u8, std.mem.span(args[1]), "-")) {
            return error.MissingWorktreeBranch;
        }

        try validateReference(action, std.mem.span(args[1]));
        options.branch = args[1];
        index = 2;
    }

    var cursor: Cursor = .{ .remaining = args[index..] };
    while (cursor.next()) |argument| {
        const arg = std.mem.span(argument);
        if (std.mem.eql(u8, arg, "--")) {
            try options.takeCommand(cursor.remaining);
            break;
        } else if (std.mem.eql(u8, arg, "--setup") and action == .create) {
            options.setup = true;
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
        } else if (std.mem.eql(u8, arg, "--machine") and (action == .create or action == .fetch)) {
            options.machine = try single(options.machine, try cursor.require(error.MissingMachineLabel));
            try core.MachineProfile.validateLabel(std.mem.span(options.machine.?));
        } else if (std.mem.eql(u8, arg, "--dispatched-from") and action == .create) {
            options.dispatched_from = try single(options.dispatched_from, try cursor.require(error.MissingMachineLabel));
            try validateText(std.mem.span(options.dispatched_from.?), core.MachineProfile.max_label_bytes);
        } else if (std.mem.eql(u8, arg, "--repository") and action == .resolve) {
            options.repository = try single(options.repository, try cursor.require(error.MissingRepository));
            try validateText(std.mem.span(options.repository.?), max_repository_bytes);
        } else if (std.mem.eql(u8, arg, "--workspace") and (action == .create or action == .list or action == .resolve)) {
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

    if (action == .fetch and options.machine == null) {
        return error.MissingMachineLabel;
    }

    if (action == .resolve and options.repository == null) {
        return error.MissingRepository;
    }

    if (options.machine != null and options.directory != null) {
        return error.DirectoryOnAnotherMachine;
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

/// `create` and `fetch` name a branch Git will make or move. The other
/// actions name a worktree telar knows, by its branch or by its title, so
/// they take any printable text a branch or a title could be.
fn validateReference(action: Action, reference: []const u8) !void {
    switch (action) {
        .create, .fetch => try workspace_grammar.validateWorktreeBranch(reference),
        .exec, .open, .diff, .remove => try validateText(reference, @max(workspace_grammar.max_worktree_branch_bytes, core.max_worktree_title_bytes)),
        .list, .resolve => unreachable,
    }
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
    try std.testing.expectError(error.InvalidWorktreeBranch, WorktreeOptions.parse(&.{ "create", "a..b" }));
    try std.testing.expectError(error.UnknownWorktreeOption, WorktreeOptions.parse(&.{ "diff", "fix", "--force" }));
    try std.testing.expectError(error.RelativeWorktreeDirectory, WorktreeOptions.parse(&.{ "create", "fix", "--directory", "rel" }));
    const removal = try WorktreeOptions.parse(&.{ "remove", "fix", "--force", "--delete-branch" });
    try std.testing.expect(removal.force and removal.delete_branch);
}

test "commands on an existing worktree take its title as well as its branch" {
    for ([_][*:0]const u8{ "open", "diff", "remove" }) |action| {
        const options = try WorktreeOptions.parse(&.{ action, "Fix tabs" });
        try std.testing.expectEqualStrings("Fix tabs", std.mem.span(options.branch.?));
    }

    _ = try WorktreeOptions.parse(&.{ "exec", "Ordenar pestañas", "--", "ls" });
    try std.testing.expectError(error.InvalidWorktreeText, WorktreeOptions.parse(&.{ "open", "Fix\x1b[2J" }));
    try std.testing.expectError(error.InvalidWorktreeBranch, WorktreeOptions.parse(&.{ "create", "Fix tabs" }));
}

test "every branch create accepts fits the protocol, so the runtime stores it whole" {
    const longest = "b" ** workspace_grammar.max_worktree_branch_bytes;
    const options = try WorktreeOptions.parse(&.{ "create", longest });
    try core.validateWorktreeText(.{
        .path = "/src/telar-worktrees/b",
        .branch = std.mem.span(options.branch.?),
        .base = std.mem.span(options.branch.?),
    });

    try std.testing.expectError(error.InvalidWorktreeBranch, WorktreeOptions.parse(&.{ "create", longest ++ "b" }));
}

test "a worktree on another machine names it; fetch needs one and resolve a repository" {
    const remote = try WorktreeOptions.parse(&.{ "create", "fix", "--machine", "box", "--from", "HEAD", "--title", "Fix", "--", "claude", "go" });
    try std.testing.expectEqualStrings("box", std.mem.span(remote.machine.?));

    const fetched = try WorktreeOptions.parse(&.{ "fetch", "fix", "--machine", "box", "--json" });
    try std.testing.expectEqual(Action.fetch, fetched.action);
    try std.testing.expectError(error.MissingMachineLabel, WorktreeOptions.parse(&.{ "fetch", "fix" }));
    try std.testing.expectError(error.InvalidMachineLabel, WorktreeOptions.parse(&.{ "create", "fix", "--machine", "-box" }));
    try std.testing.expectError(error.DirectoryOnAnotherMachine, WorktreeOptions.parse(&.{ "create", "fix", "--machine", "box", "--directory", "/src/fix" }));
    try std.testing.expectError(error.UnknownWorktreeOption, WorktreeOptions.parse(&.{ "exec", "fix", "--machine", "box", "--", "ls" }));

    const resolved = try WorktreeOptions.parse(&.{ "resolve", "--repository", "github.com/o/r", "--json" });
    try std.testing.expectEqualStrings("github.com/o/r", std.mem.span(resolved.repository.?));
    try std.testing.expectError(error.MissingRepository, WorktreeOptions.parse(&.{"resolve"}));

    const dispatched = try WorktreeOptions.parse(&.{ "create", "fix", "--dispatched-from", "laptop" });
    try std.testing.expectEqualStrings("laptop", std.mem.span(dispatched.dispatched_from.?));
}
