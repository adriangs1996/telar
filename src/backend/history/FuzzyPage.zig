const core = @import("telar-core");
const Scored = @import("Scored.zig");
const Query = @import("Query.zig");
const FuzzyPage = @This();

pub const max_candidates = 1000;

best: [max_candidates]Scored = undefined,
count: usize = 0,
wanted: usize,

/// Example: `var ranking = FuzzyPage.init(request);`.
pub fn init(request: *const Query) FuzzyPage {
    return .{ .wanted = @intCast(@min(@as(u64, request.offset) + request.limit + 1, max_candidates)) };
}

/// Keeps newer candidates ahead of older candidates on equal scores.
/// Example: `ranking.consider(.{ .id = id, .command = text }, query);`.
pub fn consider(self: *FuzzyPage, candidate: struct { id: i64, command: []const u8 }, query: []const u8) void {
    const score = core.score(candidate.command, query) orelse return;
    if (self.count == self.wanted and score <= self.best[self.count - 1].score) {
        return;
    }

    var index = self.count;
    if (self.count == self.wanted) {
        index -= 1;
    } else {
        self.count += 1;
    }

    while (index > 0 and self.best[index - 1].score < score) : (index -= 1) {
        self.best[index] = self.best[index - 1];
    }

    self.best[index] = .{ .score = score, .id = candidate.id };
}
