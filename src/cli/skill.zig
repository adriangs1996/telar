//! Prints the agent skills bundled with this binary, so an agent can learn
//! the CLI that matches the runtime it is running in: `telar` teaches how to
//! discover the commands from the binary's own help, `coordinator` how to
//! delegate tasks to agents in worktrees.

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
