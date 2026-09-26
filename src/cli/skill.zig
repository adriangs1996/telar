//! Prints the agent skill bundled with this binary, so an agent can learn the
//! CLI that matches the runtime it is running in.

const std = @import("std");

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

test "the coordinator skill names every command it relies on" {
    for ([_][]const u8{ "worktree create", "worktree list", "worktree diff", "worktree exec", "agent interrupt", "--interrupt", "--until finished", "worktree:" }) |command| {
        try std.testing.expect(std.mem.indexOf(u8, coordinator_text, command) != null);
    }
}

test "the bundled skill documents every agent subcommand" {
    for ([_][]const u8{ "agent list", "agent get", "agent wait", "agent prompt", "agent read", "pane read", "pane send-keys", "api schema" }) |command| {
        try std.testing.expect(std.mem.indexOf(u8, text, command) != null);
    }
}
