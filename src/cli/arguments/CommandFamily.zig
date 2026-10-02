//! The first word of a telar command line that names a group of commands,
//! as `worktree` in `telar worktree create`. The parser dispatches on it,
//! and `telar FAMILY --help` lists what the family offers; a word that is
//! not a family is a program to run in a pane.

const std = @import("std");

pub const CommandFamily = enum {
    // Sessions: what the runtime keeps alive.
    workspace,
    tab,
    pane,
    worktree,
    // Agents in panes.
    agent,
    // Runtime-owned execution and transfer without a terminal.
    exec,
    repository,
    project,
    file,
    // Other machines.
    machine,
    // One attached window: what only makes sense while someone looks.
    client,
    sidebar,
    workspace_list,
    layout,
    notification,
    command,
    // Configuration and the agents' own integration.
    config,
    plugin,
    integration,
    hook,
    cli,
    gui,
    // The runtime itself and its diagnostics.
    server,
    runtime,
    diagnostics,
    history,
    proxy,
    api,

    /// The family a command line word names, with `-` for `_` as the word
    /// is typed. Null for a word that is no family.
    ///
    /// ```zig
    /// const family = CommandFamily.parse("workspace-list") orelse return null;
    /// ```
    pub fn parse(word: []const u8) ?CommandFamily {
        inline for (@typeInfo(CommandFamily).@"enum".fields) |field| {
            if (std.mem.eql(u8, word, comptime spelled(field.name))) {
                return @enumFromInt(field.value);
            }
        }

        return null;
    }

    /// The word as it is typed: `workspace-list`, not `workspace_list`.
    ///
    /// ```zig
    /// try writer.print("telar {s} --help\n", .{family.name()});
    /// ```
    pub fn name(self: CommandFamily) [:0]const u8 {
        return switch (self) {
            inline else => |tag| comptime spelled(@tagName(tag)),
        };
    }

    fn spelled(comptime field: []const u8) [:0]const u8 {
        comptime {
            var word: [field.len:0]u8 = undefined;
            for (field, 0..) |byte, index| {
                word[index] = if (byte == '_') '-' else byte;
            }

            const copy = word;
            return &copy;
        }
    }
};

test "a family is spelled with dashes and parsed back" {
    try std.testing.expectEqual(CommandFamily.workspace_list, CommandFamily.parse("workspace-list").?);
    try std.testing.expectEqualStrings("workspace-list", CommandFamily.workspace_list.name());
    try std.testing.expectEqual(CommandFamily.worktree, CommandFamily.parse("worktree").?);
    try std.testing.expect(CommandFamily.parse("workspace_list") == null);
    try std.testing.expect(CommandFamily.parse("/bin/sh") == null);
    try std.testing.expect(CommandFamily.parse("") == null);
}
