const core = @import("telar-core");
const std = @import("std");
/// Prompts one pane may send another within a sliding window. A coordinator
/// that prompts a worker which prompts back could otherwise loop without
/// end; replies are meant to travel through `agent wait`, which never
/// spends this budget.
const PromptBudget = @This();

pub const max_pairs = 32;
pub const prompts_per_window = 8;
pub const window_ms: i64 = 60 * std.time.ms_per_s;

sender: [max_pairs]core.PaneId = @splat(.invalid),
target: [max_pairs]core.PaneId = @splat(.invalid),
window_start_ms: [max_pairs]i64 = @splat(0),
count: [max_pairs]u8 = @splat(0),

/// Spends one prompt from `sender` to `target` and reports whether the budget
/// allowed it. The oldest pair makes room when every row is taken.
///
/// ```zig
/// if (!model.prompt_budget.spend(sender, target, now_ms)) return fail(.prompt_rate_limited);
/// ```
pub fn spend(self: *PromptBudget, sender: core.PaneId, target: core.PaneId, now_ms: i64) bool {
    const row = self.rowFor(sender, target, now_ms);
    if (now_ms - self.window_start_ms[row] >= window_ms) {
        self.window_start_ms[row] = now_ms;
        self.count[row] = 0;
    }

    if (self.count[row] >= prompts_per_window) {
        return false;
    }

    self.count[row] += 1;
    return true;
}

fn rowFor(self: *PromptBudget, sender: core.PaneId, target: core.PaneId, now_ms: i64) usize {
    var oldest: usize = 0;
    for (0..max_pairs) |row| {
        if (self.sender[row] == sender and self.target[row] == target) {
            return row;
        }

        if (self.window_start_ms[row] < self.window_start_ms[oldest]) {
            oldest = row;
        }
    }

    self.sender[oldest] = sender;
    self.target[oldest] = target;
    self.window_start_ms[oldest] = now_ms;
    self.count[oldest] = 0;
    return oldest;
}

test "a pair spends its window budget and recovers after the window" {
    var budget: PromptBudget = .{};
    const sender: core.PaneId = @enumFromInt(1);
    const target: core.PaneId = @enumFromInt(2);

    for (0..prompts_per_window) |_| {
        try std.testing.expect(budget.spend(sender, target, 1000));
    }

    try std.testing.expect(!budget.spend(sender, target, 1000));
    try std.testing.expect(budget.spend(target, sender, 1000));
    try std.testing.expect(budget.spend(sender, target, 1000 + window_ms));
}
