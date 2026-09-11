//! Semantic icon themes for client chrome.
//!
//! Widgets draw Unicode when no graphical replacement is available. With the
//! Nerd Font theme active, they draw a one-cell placeholder and publish a KGP
//! overlay plan. That keeps layout and interaction usable while making the
//! selected icon face independent of the host terminal font.

const Icon = @import("telar-client").Icon;
const std = @import("std");
const Theme = @import("telar-client").Theme;
const measure_module = @import("telar-core").measure;

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

/// Sixty-four visible agents can each contribute a provider and a status
/// mark. The remaining slots cover the fixed top and bottom chrome.
pub const max_marks = 160;

test "icon theme names have one canonical spelling" {
    try std.testing.expectEqual(Theme.nerd_font, try Theme.parse("NerdFont"));
    try std.testing.expectEqualStrings("nerd-font", Theme.nerd_font.canonicalName());
    try std.testing.expectError(error.UnknownIconTheme, Theme.parse("emoji"));
}

test "graphical placeholders occupy one terminal cell" {
    inline for (std.meta.fields(Icon)) |field| {
        const icon: Icon = @enumFromInt(field.value);
        try std.testing.expectEqual(@as(u16, 1), measure_module(icon.cellFallbackGlyph()));
    }
}

test "sidebar controls retain directional Unicode fallbacks" {
    try std.testing.expectEqualStrings("\u{25c0}", Icon.sidebar_collapse.unicodeGlyph());
    try std.testing.expectEqualStrings("\u{25b6}", Icon.sidebar_expand.unicodeGlyph());
    try std.testing.expectEqual(@as(u16, 1), measure_module(Icon.sidebar_collapse.unicodeGlyph()));
    try std.testing.expectEqual(@as(u16, 1), measure_module(Icon.sidebar_expand.unicodeGlyph()));
}

test "the telar mark keeps one plain cell in every layer" {
    try std.testing.expectEqualStrings("\u{25a3}", Icon.telar_mark.unicodeGlyph());
    try std.testing.expectEqualStrings(" ", Icon.telar_mark.cellFallbackGlyph());
    try std.testing.expectEqual(@as(u16, 1), measure_module(Icon.telar_mark.unicodeGlyph()));
}

test "battery icon follows charge quarters" {
    try std.testing.expectEqual(Icon.battery_empty, battery(0));
    try std.testing.expectEqual(Icon.battery_quarter, battery(24));
    try std.testing.expectEqual(Icon.battery_half, battery(49));
    try std.testing.expectEqual(Icon.battery_three_quarters, battery(74));
    try std.testing.expectEqual(Icon.battery_full, battery(75));
}
