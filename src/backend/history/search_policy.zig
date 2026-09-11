//! Pure bounded ranking and command-grouping policy, independent of SQLite.

const std = @import("std");

const stats_subcommand_leaders = [_][]const u8{
    "git", "docker", "kubectl", "cargo", "zig", "npm", "pnpm", "yarn", "make", "brew", "systemctl",
};

/// Groups multi-word tools after skipping a leading sudo.
/// Example: `const group = statsGroupKey("sudo git status");`.
pub fn statsGroupKey(command: []const u8) []const u8 {
    var rest = std.mem.trimStart(u8, command, " ");
    if (std.mem.startsWith(u8, rest, "sudo ")) {
        rest = std.mem.trimStart(u8, rest["sudo ".len..], " ");
    }

    const start = rest;
    const first_end = std.mem.indexOfScalar(u8, rest, ' ') orelse return start;
    const first = rest[0..first_end];
    for (stats_subcommand_leaders) |leader| {
        if (!std.mem.eql(u8, first, leader)) {
            continue;
        }
        const after = std.mem.trimStart(u8, rest[first_end..], " ");
        if (after.len == 0 or after[0] == '-') {
            break;
        }
        const second_end = std.mem.indexOfScalar(u8, after, ' ') orelse after.len;
        const total_len = (after.ptr + second_end) - start.ptr;
        return start[0..total_len];
    }

    return first;
}
