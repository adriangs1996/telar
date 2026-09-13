//! Compares only font settings that can change this host's rasterized output.
const std = @import("std");
const Font = @import("telar-client").GuiFont;

/// Inactive strength and macOS-only smoothing cannot evict a usable atlas.
/// Example: `if (!font_rendering.same(current, candidate)) try stageFont();`
pub fn same(current: Font, candidate: Font) bool {
    return std.meta.eql(effective(current), effective(candidate));
}

fn effective(font: Font) Font {
    var result = font;
    if (@import("builtin").os.tag != .macos) {
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
    try std.testing.expectEqual(@import("builtin").os.tag != .macos, same(.{}, .{ .thicken = true }));
}
