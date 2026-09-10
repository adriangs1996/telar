//! Semantic icon themes for client chrome.
//!
//! Widgets draw Unicode when no graphical replacement is available. With the
//! Nerd Font theme active, they draw a one-cell placeholder and publish a KGP
//! overlay plan. That keeps layout and interaction usable while making the
//! selected icon face independent of the host terminal font.

const std = @import("std");
const shared = @import("telar-core").ui;

pub const Theme = @import("telar-client").layout.icons.Theme;

pub const Icon = @import("telar-client").layout.icons.Icon;

pub fn working(frame: u8) Icon {
    return switch (frame % 4) {
        0 => .agent_working_0,
        1 => .agent_working_1,
        2 => .agent_working_2,
        else => .agent_working_3,
    };
}

pub fn battery(percent: u8) Icon {
    return if (percent == 0)
        .battery_empty
    else if (percent < 25)
        .battery_quarter
    else if (percent < 50)
        .battery_half
    else if (percent < 75)
        .battery_three_quarters
    else
        .battery_full;
}

pub const Mark = struct {
    area: shared.Rect,
    icon: Icon,
    foreground: [3]u8,
    background: [3]u8,
};

/// Sixty-four visible agents can each contribute a provider and a status
/// mark. The remaining slots cover the fixed top and bottom chrome.
pub const max_marks = 160;

pub const Plan = struct {
    marks: [max_marks]Mark = undefined,
    len: u8 = 0,

    pub fn reset(plan: *Plan) void {
        plan.len = 0;
    }

    pub fn add(plan: *Plan, mark: Mark) void {
        if (plan.len == plan.marks.len) {
            return;
        }
        plan.marks[plan.len] = mark;
        plan.len += 1;
    }

    pub fn slice(plan: *const Plan) []const Mark {
        return plan.marks[0..plan.len];
    }
};

test "icon theme names have one canonical spelling" {
    try std.testing.expectEqual(Theme.nerd_font, try Theme.parse("NerdFont"));
    try std.testing.expectEqualStrings("nerd-font", Theme.nerd_font.canonicalName());
    try std.testing.expectError(error.UnknownIconTheme, Theme.parse("emoji"));
}

test "graphical placeholders occupy one terminal cell" {
    inline for (std.meta.fields(Icon)) |field| {
        const icon: Icon = @enumFromInt(field.value);
        try std.testing.expectEqual(@as(u16, 1), shared.measure(icon.cellFallbackGlyph()));
    }
}

test "sidebar controls retain directional Unicode fallbacks" {
    try std.testing.expectEqualStrings("\u{25c0}", Icon.sidebar_collapse.unicodeGlyph());
    try std.testing.expectEqualStrings("\u{25b6}", Icon.sidebar_expand.unicodeGlyph());
    try std.testing.expectEqual(@as(u16, 1), shared.measure(Icon.sidebar_collapse.unicodeGlyph()));
    try std.testing.expectEqual(@as(u16, 1), shared.measure(Icon.sidebar_expand.unicodeGlyph()));
}

test "the telar mark keeps one plain cell in every layer" {
    try std.testing.expectEqualStrings("\u{25a3}", Icon.telar_mark.unicodeGlyph());
    try std.testing.expectEqualStrings(" ", Icon.telar_mark.cellFallbackGlyph());
    try std.testing.expectEqual(@as(u16, 1), shared.measure(Icon.telar_mark.unicodeGlyph()));
}

test "battery icon follows charge quarters" {
    try std.testing.expectEqual(Icon.battery_empty, battery(0));
    try std.testing.expectEqual(Icon.battery_quarter, battery(24));
    try std.testing.expectEqual(Icon.battery_half, battery(49));
    try std.testing.expectEqual(Icon.battery_three_quarters, battery(74));
    try std.testing.expectEqual(Icon.battery_full, battery(75));
}
