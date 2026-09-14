//! Which tokens a card keeps when its width shrinks: age leaves first, then
//! the provider mark, then the last event. The thresholds are monotone, so
//! narrowing a card never brings a token back before a wider one leaves. A
//! level is skipped when dropping its token alone would not make the card
//! fit: a short workspace label loses its age and the mark at the same width.
const std = @import("std");
const Widths = @import("CardTokenWidths.zig");

pub const Level = enum(u2) {
    full,
    no_age,
    no_mark,
    no_event,

    /// Example: `if (level.shows(.age)) paintAge();`
    pub fn shows(level: Level, token: Token) bool {
        return switch (token) {
            .age => level == .full,
            .mark => @intFromEnum(level) <= @intFromEnum(Level.no_age),
            .event => level != .no_event,
        };
    }
};

pub const Token = enum { age, mark, event };

/// Example: `const level = card_degradation.resolve(widths);`
pub fn resolve(widths: Widths) Level {
    const keep_event = widths.status + widths.gap + widths.event_min;
    const keep_mark = keep_event + widths.mark;
    const keep_age = @max(keep_mark, widths.workspace + widths.gap + widths.age);
    if (widths.available >= keep_age) {
        return .full;
    }

    if (widths.available >= keep_mark) {
        return .no_age;
    }

    if (widths.available >= keep_event) {
        return .no_mark;
    }

    return .no_event;
}

test "tokens leave from the right as the card narrows" {
    const base: Widths = .{ .available = 0, .workspace = 90, .age = 24, .status = 12, .mark = 22 };
    var widths = base;
    var previous: Level = .full;
    var width: f32 = 400;
    while (width >= 0) : (width -= 1) {
        widths.available = width;
        const level = resolve(widths);
        try std.testing.expect(@intFromEnum(level) >= @intFromEnum(previous));
        previous = level;
    }

    widths.available = 400;
    try std.testing.expectEqual(Level.full, resolve(widths));
    widths.available = 100;
    try std.testing.expectEqual(Level.no_age, resolve(widths));
    widths.available = 70;
    try std.testing.expectEqual(Level.no_mark, resolve(widths));
    widths.available = 40;
    try std.testing.expectEqual(Level.no_event, resolve(widths));
    try std.testing.expect(Level.no_age.shows(.mark));
    try std.testing.expect(!Level.no_age.shows(.age));
    try std.testing.expect(Level.no_mark.shows(.event));
    try std.testing.expect(!Level.no_event.shows(.event));
}
