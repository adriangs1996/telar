//! A color written as text: `default`, a theme role such as `accent` or
//! `panel-bg`, or `#RRGGBB`. Bars and machine profiles both name colors
//! this way.
const std = @import("std");
const bar_values = @import("model.zig");

/// Reads one written color; anything else is null.
///
/// ```zig
/// const color = color_name.parse("panel-bg") orelse return error.UnknownColor;
/// ```
pub fn parse(name: []const u8) ?bar_values.Color {
    if (std.ascii.eqlIgnoreCase(name, "default")) {
        return .{ .value = .default };
    }

    inline for (std.meta.fields(bar_values.PaletteColor)) |field| {
        if (roleNameEql(name, field.name)) {
            return .{ .palette = @enumFromInt(field.value) };
        }
    }

    if (name.len == "#RRGGBB".len and name[0] == '#') {
        const value = std.fmt.parseInt(u24, name[1..], 16) catch return null;
        return .{ .value = .rgb(.{
            @intCast((value >> 16) & 0xff),
            @intCast((value >> 8) & 0xff),
            @intCast(value & 0xff),
        }) };
    }

    return null;
}

/// Compares names case-insensitively with `-` and `_` treated alike.
pub fn roleNameEql(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) {
        return false;
    }

    for (left, right) |left_byte, right_byte| {
        const normalized_left = if (left_byte == '-') '_' else std.ascii.toLower(left_byte);
        const normalized_right = if (right_byte == '-') '_' else std.ascii.toLower(right_byte);
        if (normalized_left != normalized_right) {
            return false;
        }
    }

    return true;
}

test "roles, literals and default parse; other text does not" {
    try std.testing.expectEqual(bar_values.PaletteColor.panel_bg, parse("panel-bg").?.palette);
    try std.testing.expectEqual(bar_values.PaletteColor.red, parse("RED").?.palette);
    try std.testing.expect(parse("default").?.value.kind == .default);
    try std.testing.expect(parse("#e06c75") != null);
    try std.testing.expectEqual(@as(?bar_values.Color, null), parse("#e06c7"));
    try std.testing.expectEqual(@as(?bar_values.Color, null), parse("neon"));
}
