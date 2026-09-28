//! Human-readable key chords for palette and history hints. macOS prints
//! the modifier glyphs its menus use; every other host prints words.
//! Nothing here allocates; callers pass a buffer.
const builtin = @import("builtin");
const keyinput = @import("keyinput");
const std = @import("std");

pub const max_bytes = 64;

/// How a chord is spelled: `Ctrl+O` or `⌃O`.
pub const Style = enum {
    pc,
    mac,
};

/// The style of the host this binary runs on.
pub const host_style: Style = if (builtin.os.tag == .macos) .mac else .pc;

/// Writes `prefix suffix` (or only `suffix` without a prefix) into `buffer`.
/// Example: `const hint = chord(&storage, router.prefix, key, key_label.host_style);`.
pub fn chord(buffer: *[max_bytes]u8, prefix: ?keyinput.Key, key: keyinput.Key, style: Style) []const u8 {
    var prefix_storage: [max_bytes / 2]u8 = undefined;
    var key_storage: [max_bytes / 2]u8 = undefined;
    const suffix = format(&key_storage, key, style);
    if (prefix) |value| {
        return std.fmt.bufPrint(buffer, "{s} {s}", .{ format(&prefix_storage, value, style), suffix }) catch "?";
    }

    return std.fmt.bufPrint(buffer, "{s}", .{suffix}) catch "?";
}

/// Example: `const text = format(&storage, key, .mac);`.
pub fn format(buffer: []u8, key: keyinput.Key, style: Style) []const u8 {
    var char_storage: [8]u8 = undefined;
    const code: []const u8 = switch (key.code) {
        .char => |character| if (style == .mac) upper(character.slice(), &char_storage) else character.slice(),
        .up => if (style == .mac) "↑" else "Up",
        .down => if (style == .mac) "↓" else "Down",
        .left => if (style == .mac) "←" else "Left",
        .right => if (style == .mac) "→" else "Right",
        .home => if (style == .mac) "↖" else "Home",
        .end => if (style == .mac) "↘" else "End",
        .delete => if (style == .mac) "⌦" else "Del",
        .page_up => if (style == .mac) "⇞" else "PgUp",
        .page_down => if (style == .mac) "⇟" else "PgDn",
        .enter => if (style == .mac) "↩" else "Enter",
        .escape => if (style == .mac) "esc" else "Esc",
        .backspace => if (style == .mac) "⌫" else "Backspace",
        .tab => if (style == .mac) "⇥" else "Tab",
        .back_tab => if (style == .mac) "⇧⇥" else "Shift+Tab",
    };

    return switch (style) {
        .pc => std.fmt.bufPrint(buffer, "{s}{s}{s}{s}", .{ if (key.mods.ctrl) "Ctrl+" else "", if (key.mods.alt) "Alt+" else "", if (key.mods.shift) "Shift+" else "", code }) catch "?",
        .mac => std.fmt.bufPrint(buffer, "{s}{s}{s}{s}", .{ if (key.mods.ctrl) "⌃" else "", if (key.mods.alt) "⌥" else "", if (key.mods.shift) "⇧" else "", code }) catch "?",
    };
}

// Menus print letters in capitals next to their modifiers.
fn upper(text: []const u8, storage: *[8]u8) []const u8 {
    if (text.len != 1 or !std.ascii.isLower(text[0])) {
        return text;
    }

    storage[0] = std.ascii.toUpper(text[0]);
    return storage[0..1];
}

test "chords print the prefix before the bound suffix in both styles" {
    var storage: [max_bytes]u8 = undefined;
    const prefix = try keyinput.chord.parseKey("ctrl+b");
    try std.testing.expectEqualStrings("Ctrl+b %", chord(
        &storage,
        prefix,
        try keyinput.chord.parseKey("%"),
        .pc,
    ));
    try std.testing.expectEqualStrings("⌃B %", chord(
        &storage,
        prefix,
        try keyinput.chord.parseKey("%"),
        .mac,
    ));
    try std.testing.expectEqualStrings("Shift+Left", chord(
        &storage,
        null,
        try keyinput.chord.parseKey("shift+left"),
        .pc,
    ));
    try std.testing.expectEqualStrings("⇧←", chord(
        &storage,
        null,
        try keyinput.chord.parseKey("shift+left"),
        .mac,
    ));
    try std.testing.expectEqualStrings("⌃O", format(&storage, try keyinput.chord.parseKey("ctrl+o"), .mac));
    try std.testing.expectEqualStrings("Ctrl+o", format(&storage, try keyinput.chord.parseKey("ctrl+o"), .pc));
}
