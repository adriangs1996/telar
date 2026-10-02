//! Prints the agent skills bundled with this binary, so an agent can learn
//! the CLI that matches the runtime it is running in: `telar` teaches how to
//! discover the commands from the binary's own help, `coordinator` how to
//! delegate tasks to agents in worktrees.

const std = @import("std");
const help = @import("help.zig");
const CommandFamily = @import("arguments/CommandFamily.zig").CommandFamily;

pub const text = @embedFile("skill/telar.md");
pub const coordinator_text = @embedFile("skill/coordinator.md");

/// Which bundled skill `telar --skill` prints.
pub const Skill = enum { telar, coordinator };

/// Writes one bundled skill to stdout.
///
/// ```zig
/// try skill.run(process_init, .coordinator);
/// ```
pub fn run(init: std.process.Init, which: Skill) !void {
    const selected = switch (which) {
        .telar => text,
        .coordinator => coordinator_text,
    };
    try std.Io.File.stdout().writeStreamingAll(init.io, selected);
}

// Every `telar FAMILY COMMAND` a skill quotes, in a code span or a code
// block, must be a command the help knows, so the skills never drift from the
// CLI. A word after the family that starts with `-` or `<` is an option or a
// placeholder, not a command.
fn expectCommandsExist(skill_text: []const u8) !void {
    var rest = skill_text;
    while (std.mem.indexOf(u8, rest, "telar ")) |start| {
        const quote: ?u8 = if (start == 0) null else switch (rest[start - 1]) {
            '`' => '`',
            '\n' => '\n',
            else => null,
        };
        rest = rest[start + "telar ".len ..];
        const closing = quote orelse continue;
        const span = rest[0 .. std.mem.indexOfScalar(u8, rest, closing) orelse rest.len];
        var words = std.mem.tokenizeAny(u8, span, " \n|)");
        const first = words.next() orelse continue;
        const which = CommandFamily.parse(first) orelse continue;
        const second = words.next() orelse continue;
        if (second[0] == '-' or second[0] == '<' or second[0] == '.') {
            continue;
        }

        if (help.family(which).find(second) == null) {
            std.debug.print("skill names `telar {s} {s}`, which the help does not know\n", .{ first, second });
            return error.UnknownSkillCommand;
        }
    }
}

test "the skills name only commands the help knows" {
    try expectCommandsExist(text);
    try expectCommandsExist(coordinator_text);
}

test "the general skill teaches discovery through help, not a command catalog" {
    for ([_][]const u8{ "telar --help", "telar FAMILY --help", "telar FAMILY COMMAND --help", "TELAR_BIN_PATH", "--skill coordinator" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, text, needle) != null);
    }

    // Every family the root help lists is on the skill's capability map.
    inline for (@typeInfo(CommandFamily).@"enum".fields) |field| {
        const which: CommandFamily = @enumFromInt(field.value);
        try std.testing.expect(std.mem.indexOf(u8, text, "`" ++ comptime which.name() ++ "`") != null);
    }

    // Numeric limits belong to the command help.
    try std.testing.expect(std.mem.indexOf(u8, text, "KiB") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, " ms") == null);
}
