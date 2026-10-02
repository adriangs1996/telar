//! Help from the binary alone: `telar --help` maps the command families,
//! `telar FAMILY --help` lists a family's commands and `telar FAMILY COMMAND
//! --help` explains one command's arguments, effects and results. Help never
//! connects to a runtime, starts one or runs the command, and a `--help`
//! after `--` belongs to the child command, not to telar.

const std = @import("std");
const build_options = @import("build_options");
const CommandFamily = @import("arguments/CommandFamily.zig").CommandFamily;
const CommandHelp = @import("CommandHelp.zig");
const FamilyHelp = @import("FamilyHelp.zig");
const HelpTopic = @import("HelpTopic.zig").HelpTopic;
const workspace_help = @import("help/workspace.zig");
const tab_help = @import("help/tab.zig");
const pane_help = @import("help/pane.zig");
const worktree_help = @import("help/worktree.zig");
const agent_help = @import("help/agent.zig");
const exec_help = @import("help/exec.zig");
const repository_help = @import("help/repository.zig");
const project_help = @import("help/project.zig");
const file_help = @import("help/file.zig");
const machine_help = @import("help/machine.zig");
const client_help = @import("help/client.zig");
const sidebar_help = @import("help/sidebar.zig");
const workspace_list_help = @import("help/workspace_list.zig");
const layout_help = @import("help/layout.zig");
const notification_help = @import("help/notification.zig");
const command_help = @import("help/command.zig");
const config_help = @import("help/config.zig");
const plugin_help = @import("help/plugin.zig");
const integration_help = @import("help/integration.zig");
const hook_help = @import("help/hook.zig");
const cli_help = @import("help/cli.zig");
const gui_help = @import("help/gui.zig");
const server_help = @import("help/server.zig");
const runtime_help = @import("help/runtime.zig");
const diagnostics_help = @import("help/diagnostics.zig");
const history_help = @import("help/history.zig");
const proxy_help = @import("help/proxy.zig");
const api_help = @import("help/api.zig");

/// The flags that ask for help, before `--`.
const flags = [_][]const u8{ "--help", "-h" };

/// A heading of the root listing and the families under it.
const Group = struct {
    title: []const u8,
    families: []const CommandFamily,
};

/// The capability map `telar --help` prints: every family once, under the
/// question it answers.
const groups = [_]Group{
    .{ .title = "Sessions (what the runtime keeps alive)", .families = &.{ .workspace, .tab, .pane, .worktree } },
    .{ .title = "Agents (running in panes)", .families = &.{.agent} },
    .{ .title = "Execution (runtime-owned, no terminal)", .families = &.{ .exec, .repository, .project, .file } },
    .{ .title = "Machines (other computers)", .families = &.{.machine} },
    .{ .title = "Window (one attached client)", .families = &.{ .client, .sidebar, .workspace_list, .layout, .notification, .command } },
    .{ .title = "Configuration and agent integration", .families = &.{ .config, .plugin, .integration, .hook, .cli, .gui } },
    .{ .title = "Runtime and diagnostics", .families = &.{ .server, .runtime, .diagnostics, .history, .proxy, .api } },
};

/// What `--help` on a command line asks for, or null when it asks for no
/// help: no flag before `--`, or a first word that is a program, whose
/// `--help` is its own.
///
/// ```zig
/// if (help.find(args[1..])) |topic| return .{ .help = topic };
/// ```
pub fn find(args: []const [*:0]const u8) ?HelpTopic {
    if (args.len == 0) {
        return null;
    }

    const first = std.mem.span(args[0]);
    if (isFlag(first)) {
        return .root;
    }

    const which = CommandFamily.parse(first) orelse return null;
    const asked = for (args[1..]) |argument| {
        const arg = std.mem.span(argument);
        if (std.mem.eql(u8, arg, "--")) {
            break false;
        }

        if (isFlag(arg)) {
            break true;
        }
    } else false;
    if (!asked) {
        return null;
    }

    if (args.len > 1) {
        if (family(which).find(std.mem.span(args[1]))) |command| {
            return .{ .command = .{ .family = which, .command = command } };
        }
    }

    return .{ .family = which };
}

/// The help of one family. Every family has one: a new family does not
/// compile until it says what it offers.
///
/// ```zig
/// for (help.family(.worktree).commands) |command| try writer.print("{s}\n", .{command.name});
/// ```
pub fn family(which: CommandFamily) FamilyHelp {
    return switch (which) {
        .workspace => workspace_help.family,
        .tab => tab_help.family,
        .pane => pane_help.family,
        .worktree => worktree_help.family,
        .agent => agent_help.family,
        .exec => exec_help.family,
        .repository => repository_help.family,
        .project => project_help.family,
        .file => file_help.family,
        .machine => machine_help.family,
        .client => client_help.family,
        .sidebar => sidebar_help.family,
        .workspace_list => workspace_list_help.family,
        .layout => layout_help.family,
        .notification => notification_help.family,
        .command => command_help.family,
        .config => config_help.family,
        .plugin => plugin_help.family,
        .integration => integration_help.family,
        .hook => hook_help.family,
        .cli => cli_help.family,
        .gui => gui_help.family,
        .server => server_help.family,
        .runtime => runtime_help.family,
        .diagnostics => diagnostics_help.family,
        .history => history_help.family,
        .proxy => proxy_help.family,
        .api => api_help.family,
    };
}

/// Writes one help topic to standard output.
///
/// ```zig
/// try help.run(process_init, .root);
/// ```
pub fn run(init: std.process.Init, selected: HelpTopic) !void {
    var buffer: [16 * 1024]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try write(&output.interface, selected);
    try output.interface.flush();
}

/// Writes one help topic.
///
/// ```zig
/// try help.write(writer, .{ .family = .worktree });
/// ```
pub fn write(writer: *std.Io.Writer, selected: HelpTopic) !void {
    switch (selected) {
        .root => try writer.writeAll(root_text),
        .family => |which| try writeFamily(writer, which),
        .command => |chosen| try writeCommand(writer, chosen.family, chosen.command),
    }
}

fn writeFamily(writer: *std.Io.Writer, which: CommandFamily) !void {
    const selected = family(which);
    try writer.print("telar {s}: {s}\n\nUsage: {s}\n", .{ which.name(), selected.summary, selected.usage });
    var listed = false;
    for (selected.commands) |command| {
        if (command.hidden) {
            continue;
        }

        if (!listed) {
            try writer.writeAll("\nCommands:\n");
            listed = true;
        }

        try writer.print("  {s:<16}{s}\n", .{ command.name, command.summary });
    }

    if (selected.text.len != 0) {
        try writer.print("\n{s}", .{selected.text});
    }

    if (listed) {
        try writer.print("\n`telar {s} COMMAND --help` explains a command's arguments, effects and results.\n", .{which.name()});
    }
}

fn writeCommand(writer: *std.Io.Writer, which: CommandFamily, command: *const CommandHelp) !void {
    try writer.print("telar {s} {s}: {s}\n\nUsage: {s}\n\n{s}", .{ which.name(), command.name, command.summary, command.usage, command.text });
}

fn isFlag(arg: []const u8) bool {
    for (flags) |flag| {
        if (std.mem.eql(u8, arg, flag)) {
            return true;
        }
    }

    return false;
}

/// The family listing of the root help, built once at compile time from
/// the groups and each family's summary.
const family_listing = blk: {
    var text: []const u8 = "";
    for (groups) |group| {
        text = text ++ "\n" ++ group.title ++ "\n";
        for (group.families) |which| {
            text = text ++ std.fmt.comptimePrint("  {s:<16}{s}\n", .{ which.name(), family(which).summary });
        }
    }

    break :blk text;
};

pub const root_text = "telar " ++ build_options.version ++ ": a terminal multiplexer and runtime for agents.\n" ++
    \\
    \\Usage: telar [options] [COMMAND [ARGS...]]      run a shell, or COMMAND, in a pane of a window
    \\       telar FAMILY COMMAND [ARGS...]          one operation on the runtime, an agent or a window
    \\       telar --machine LABEL FAMILY COMMAND... the same operation on a saved machine
    \\
    \\Discover from the binary you run: `telar FAMILY --help` lists a family's commands and
    \\`telar FAMILY COMMAND --help` explains one command's arguments, effects and results.
    \\Help never starts or contacts a runtime, and `--help` after `--` belongs to the child.
    \\Most commands take `--json` for structured output and `--socket PATH` to name a runtime.
    \\
    \\Families:
    \\
++ family_listing ++
    \\
    \\Options before COMMAND:
    \\  --config PATH     Load a specific Lua configuration (default: $XDG_CONFIG_HOME/telar/config.lua)
    \\  --no-config       Do not load Lua configuration
    \\  --profile NAME    Overlay a named Lua profile before CLI options
    \\  --theme NAME      UI theme: shade, vesper, catppuccin, tokyo-night, kanagawa,
    \\                    kanagawa-dragon, pierre-dark, pierre-dark-soft, terminal
    \\  --remote DEST     Attach to the runtime on an SSH host (needs telar on the remote PATH)
    \\  --machine LABEL   Show a saved machine first; the window still holds every enabled one
    \\  --fresh           Start a runtime that sets the previous session aside instead of
    \\                    restoring it; refused while a runtime is already running
    \\  --skill [telar|coordinator]  Print a bundled agent skill; `telar` is the discovery guide
    \\  -h, --help        Show this help
    \\  -V, --version     Show the version
    \\  --                Stop parsing telar options; what follows is the command
    \\
    \\Environment inside a pane: TELAR_SOCKET_PATH, TELAR_PANE_ID, TELAR_PANE_GENERATION,
    \\TELAR_WORKSPACE_ID, TELAR_TAB_ID and TELAR_BIN_PATH, which `--current` and `telar` resolve.
    \\
    \\Default keybindings (prefix Ctrl-b):
    \\  % / "            Split left/right or top/bottom
    \\  Arrow keys       Focus a pane by direction
    \\  Shift+arrows     Resize the focused pane
    \\  z                Toggle pane fullscreen
    \\  s                Toggle the sidebar
    \\  w                Toggle the workspace list
    \\  N                Create and select a workspace
    \\  W                Rename the active workspace
    \\  x                Close the focused pane
    \\  [                Enter copy mode
    \\  g                Open the goto picker
    \\  /                Search command history
    \\  c                Create and select a tab
    \\  n / p            Select the next or previous tab
    \\  1..9             Select a tab by position
    \\  T                Rename the active tab
    \\  X                Close the active tab
    \\  , / .            Move the active tab left or right
    \\  d                Detach the client
    \\
;

test "the root listing names every family once" {
    inline for (@typeInfo(CommandFamily).@"enum".fields) |field| {
        const which: CommandFamily = @enumFromInt(field.value);
        var seen: usize = 0;
        for (groups) |group| {
            for (group.families) |listed| {
                if (listed == which) {
                    seen += 1;
                }
            }
        }

        try std.testing.expectEqual(@as(usize, 1), seen);
        try std.testing.expect(std.mem.indexOf(u8, root_text, "\n  " ++ comptime which.name()) != null);
    }
}

test "help is found at the root, the family and the command, never after the separator" {
    try std.testing.expect(find(&.{"--help"}).? == .root);
    try std.testing.expect(find(&.{"-h"}).? == .root);
    try std.testing.expectEqual(CommandFamily.worktree, find(&.{ "worktree", "--help" }).?.family);
    try std.testing.expectEqual(CommandFamily.exec, find(&.{ "exec", "--cwd", "/tmp", "-h" }).?.family);
    try std.testing.expectEqual(CommandFamily.workspace_list, find(&.{ "workspace-list", "--help" }).?.family);

    const created = find(&.{ "worktree", "create", "--help" }).?.command;
    try std.testing.expectEqual(CommandFamily.worktree, created.family);
    try std.testing.expectEqualStrings("create", created.command.name);
    try std.testing.expectEqualStrings("split", find(&.{ "pane", "split", "4", "horizontal", "--client", "1", "--help" }).?.command.command.name);
    try std.testing.expectEqualStrings("trust", find(&.{ "proxy", "trust", "install", "--help" }).?.command.command.name);

    try std.testing.expect(find(&.{ "worktree", "exec", "fix", "--", "claude", "--help" }) == null);
    try std.testing.expect(find(&.{ "exec", "--", "ls", "--help" }) == null);
    try std.testing.expect(find(&.{ "/bin/sh", "--help" }) == null);
    try std.testing.expect(find(&.{ "worktree", "list" }) == null);
    try std.testing.expect(find(&.{}) == null);
}

test "every family prints its usage, its visible commands and the way deeper" {
    inline for (@typeInfo(CommandFamily).@"enum".fields) |field| {
        const which: CommandFamily = @enumFromInt(field.value);
        var buffer: [32 * 1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try write(&writer, .{ .family = which });
        const text = writer.buffered();
        try std.testing.expect(std.mem.startsWith(u8, text, "telar " ++ comptime which.name() ++ ": "));
        try std.testing.expect(std.mem.indexOf(u8, text, "\nUsage: telar " ++ comptime which.name()) != null);
        for (family(which).commands) |command| {
            var line_buffer: [128]u8 = undefined;
            const line = try std.fmt.bufPrint(&line_buffer, "\n  {s:<16}{s}\n", .{ command.name, command.summary });
            try std.testing.expectEqual(!command.hidden, std.mem.indexOf(u8, text, line) != null);
        }
    }
}

test "every command's usage names it and its help is reachable from the family" {
    inline for (@typeInfo(CommandFamily).@"enum".fields) |field| {
        const which: CommandFamily = @enumFromInt(field.value);
        for (family(which).commands) |*command| {
            var prefix_buffer: [128]u8 = undefined;
            const prefix = try std.fmt.bufPrint(&prefix_buffer, "telar {s} {s}", .{ which.name(), command.name });
            try std.testing.expect(std.mem.startsWith(u8, command.usage, prefix));
            try std.testing.expect(command.examples.len != 0);
            try std.testing.expectEqual(command, family(which).find(command.name).?);

            var buffer: [32 * 1024]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buffer);
            try write(&writer, .{ .command = .{ .family = which, .command = command } });
            try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), prefix));
        }
    }
}

/// The family and command words a command line names, followed by a space,
/// for a hint such as `see telar worktree create --help`; empty when the
/// first word is no family.
///
/// ```zig
/// std.debug.print("see `telar {s}--help`\n", .{help.topic(args, &buffer)});
/// ```
pub fn topic(args: []const [*:0]const u8, buffer: []u8) []const u8 {
    if (args.len < 2) {
        return "";
    }

    const which = CommandFamily.parse(std.mem.span(args[1])) orelse return "";
    const command = if (args.len > 2) family(which).find(std.mem.span(args[2])) else null;
    const written = if (command) |selected|
        std.fmt.bufPrint(buffer, "{s} {s} ", .{ which.name(), selected.name })
    else
        std.fmt.bufPrint(buffer, "{s} ", .{which.name()});
    return written catch "";
}

test "a hint names the family and the command the arguments reached" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("worktree create ", topic(&.{ "telar", "worktree", "create" }, &buffer));
    try std.testing.expectEqualStrings("worktree ", topic(&.{ "telar", "worktree", "frobnicate" }, &buffer));
    try std.testing.expectEqualStrings("", topic(&.{ "telar", "/bin/sh" }, &buffer));
    try std.testing.expectEqualStrings("", topic(&.{"telar"}, &buffer));
}
