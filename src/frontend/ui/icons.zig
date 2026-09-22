//! Semantic icon themes for client chrome.
//!
//! Widgets draw Unicode when no graphical replacement is available. With the
//! Nerd Font theme active, they draw a one-cell placeholder and publish a KGP
//! overlay plan. That keeps layout and interaction usable while making the
//! selected icon face independent of the host terminal font.

const client = @import("telar-client");
const core = @import("telar-core");
const std = @import("std");

pub fn working(frame: u8) client.Icon {
    return switch (frame % 4) {
        0 => .agent_working_0,
        1 => .agent_working_1,
        2 => .agent_working_2,
        else => .agent_working_3,
    };
}

pub fn battery(percent: u8) client.Icon {
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
    try std.testing.expectEqual(client.Theme.nerd_font, try client.Theme.parse("NerdFont"));
    try std.testing.expectEqualStrings("nerd-font", client.Theme.nerd_font.canonicalName());
    try std.testing.expectError(error.UnknownIconTheme, client.Theme.parse("emoji"));
}

test "graphical placeholders occupy one terminal cell" {
    inline for (std.meta.fields(client.Icon)) |field| {
        const icon: client.Icon = @enumFromInt(field.value);
        try std.testing.expectEqual(@as(u16, 1), core.measure(icon.cellFallbackGlyph()));
    }
}

test "sidebar controls retain directional Unicode fallbacks" {
    try std.testing.expectEqualStrings("\u{25c0}", client.Icon.sidebar_collapse.unicodeGlyph());
    try std.testing.expectEqualStrings("\u{25b6}", client.Icon.sidebar_expand.unicodeGlyph());
    try std.testing.expectEqual(@as(u16, 1), core.measure(client.Icon.sidebar_collapse.unicodeGlyph()));
    try std.testing.expectEqual(@as(u16, 1), core.measure(client.Icon.sidebar_expand.unicodeGlyph()));
}

test "the telar mark keeps one plain cell in every layer" {
    try std.testing.expectEqualStrings("\u{25a3}", client.Icon.telar_mark.unicodeGlyph());
    try std.testing.expectEqualStrings(" ", client.Icon.telar_mark.cellFallbackGlyph());
    try std.testing.expectEqual(@as(u16, 1), core.measure(client.Icon.telar_mark.unicodeGlyph()));
}

test "battery icon follows charge quarters" {
    try std.testing.expectEqual(client.Icon.battery_empty, battery(0));
    try std.testing.expectEqual(client.Icon.battery_quarter, battery(24));
    try std.testing.expectEqual(client.Icon.battery_half, battery(49));
    try std.testing.expectEqual(client.Icon.battery_three_quarters, battery(74));
    try std.testing.expectEqual(client.Icon.battery_full, battery(75));
}
