//! Pure bounded ranking and command-grouping policy, independent of SQLite.
const std = @import("std");
const fuzzy = @import("telar-core").fuzzy;
const model = @import("model.zig");

pub const FuzzyPage = struct {
    pub const max_candidates = 1000;
    const Scored = struct { score: u32, id: i64 };
    best: [max_candidates]Scored = undefined,
    count: usize = 0,
    wanted: usize,

    /// Example: `var ranking = FuzzyPage.init(request);`.
    pub fn init(request: *const model.Query) FuzzyPage {
        return .{ .wanted = @intCast(@min(@as(u64, request.offset) + request.limit + 1, max_candidates)) };
    }

    /// Keeps newer candidates ahead of older candidates on equal scores.
    /// Example: `ranking.consider(.{ .id = id, .command = text }, query);`.
    pub fn consider(ranking: *FuzzyPage, candidate: struct { id: i64, command: []const u8 }, query: []const u8) void {
        const score = fuzzy.score(candidate.command, query) orelse return;
        if (ranking.count == ranking.wanted and score <= ranking.best[ranking.count - 1].score) {
            return;
        }

        var index = ranking.count;
        if (ranking.count == ranking.wanted) {
            index -= 1;
        } else {
            ranking.count += 1;
        }

        while (index > 0 and ranking.best[index - 1].score < score) : (index -= 1) {
            ranking.best[index] = ranking.best[index - 1];
        }

        ranking.best[index] = .{ .score = score, .id = candidate.id };
    }
};

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
