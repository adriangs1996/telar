//! Compares only font settings that can change this host's rasterized output.
const builtin = @import("builtin");
const client = @import("telar-client");
const std = @import("std");

/// Inactive strength and macOS-only smoothing cannot evict a usable atlas.
/// Example: `if (!font_rendering.same(current, candidate)) try stageFont();`
pub fn same(current: client.GuiFont, candidate: client.GuiFont) bool {
    return std.meta.eql(effective(current), effective(candidate));
}

fn effective(font: client.GuiFont) client.GuiFont {
    var result = font;
    if (builtin.os.tag != .macos) {
        result.thicken = false;
    }

    if (!result.thicken) {
        result.thicken_strength = 255;
    }

    return result;
}

test "font comparison ignores inactive optical weight but preserves geometry settings" {
    try std.testing.expect(same(.{}, .{ .thicken_strength = 1 }));
    try std.testing.expect(!same(.{}, .{ .size = 16 }));
    try std.testing.expectEqual(builtin.os.tag != .macos, same(.{}, .{ .thicken = true }));
}
