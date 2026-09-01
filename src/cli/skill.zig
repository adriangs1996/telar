//! Prints the agent skill bundled with this binary, so an agent can learn the
//! CLI that matches the runtime it is running in.

const std = @import("std");

const File = std.Io.File;

pub const text = @embedFile("skill/telar.md");

/// Writes the bundled skill to stdout.
///
/// ```zig
/// try skill.run(process_init);
/// ```
pub fn run(init: std.process.Init) !void {
    try File.stdout().writeStreamingAll(init.io, text);
}

test "the bundled skill documents every agent subcommand" {
    for ([_][]const u8{ "agent list", "agent get", "agent wait", "agent prompt", "agent read", "pane read", "pane send-keys", "api schema" }) |command| {
        try std.testing.expect(std.mem.indexOf(u8, text, command) != null);
    }
}
