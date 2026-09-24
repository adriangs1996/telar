const std = @import("std");
const Point = @import("Point.zig");
const select = @import("selection.zig");
/// Turns a stream of presses into a granularity.
///
/// Double and triple click are a *timing* fact, not a mouse fact: the terminal
/// reports three presses and nothing else. The threshold is time and position
/// together, because two clicks far apart are two clicks no matter how quickly
/// they arrived.
const ClickTracker = @This();

/// The interval every desktop has used since the 1980s. Shorter feels
/// broken to anyone who types slowly; longer turns two deliberate clicks
/// into a double.
interval_ns: u64 = 500 * std.time.ns_per_ms,
last_ns: u64 = 0,
last: Point = .{ .x = 0, .y = 0 },
count: u8 = 0,

pub fn press(self: *ClickTracker, at: Point, now_ns: u64) select.Granularity {
    const near = at.y == self.last.y and (if (at.x > self.last.x) at.x - self.last.x else self.last.x - at.x) <= 1;
    const soon = self.count > 0 and now_ns -| self.last_ns <= self.interval_ns;

    self.count = if (near and soon) @min(self.count +| 1, 3) else 1;
    self.last = at;
    self.last_ns = now_ns;

    return switch (self.count) {
        1 => .character,
        2 => .word,
        // Past three it stays on line rather than cycling: a user holding
        // down the button is asking for more, never for less.
        else => .line,
    };
}
