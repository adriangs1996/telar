const FuzzyPage = @This();
const model = @import("model.zig");
const fuzzy = @import("telar-core").fuzzy;
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
