//! Human-readable key chords for palette hints, formatted the way the mode
//! bar prints prefix hints. Nothing here allocates; callers pass a buffer.
const std = @import("std");
const client = @import("telar-client");

pub const max_bytes = 64;

/// Writes `prefix suffix` (or only `suffix` without a prefix) into `buffer`.
/// Example: `const hint = chord(&storage, router.prefix, key);`.
pub fn chord(buffer: *[max_bytes]u8, prefix: ?client.Key, key: client.Key) []const u8 {
    var prefix_storage: [max_bytes / 2]u8 = undefined;
    var key_storage: [max_bytes / 2]u8 = undefined;
    const suffix = format(&key_storage, key);
    if (prefix) |value| {
        return std.fmt.bufPrint(buffer, "{s} {s}", .{ format(&prefix_storage, value), suffix }) catch "?";
    }

    return std.fmt.bufPrint(buffer, "{s}", .{suffix}) catch "?";
}

/// Example: `const text = format(&storage, key);`.
pub fn format(buffer: []u8, key: client.Key) []const u8 {
    const code = switch (key.code) {
        .char => |character| character.slice(),
        .up => "Up",
        .down => "Down",
        .left => "Left",
        .right => "Right",
        .home => "Home",
        .end => "End",
        .delete => "Del",
        .page_up => "PgUp",
        .page_down => "PgDn",
        .enter => "Enter",
        .escape => "Esc",
        .backspace => "Backspace",
        .tab => "Tab",
        .back_tab => "BackTab",
    };

    return std.fmt.bufPrint(buffer, "{s}{s}{s}{s}", .{ if (key.mods.ctrl) "Ctrl+" else "", if (key.mods.alt) "Alt+" else "", if (key.mods.shift) "Shift+" else "", code }) catch "?";
}

test "chords print the prefix before the bound suffix" {
    var storage: [max_bytes]u8 = undefined;
    const prefix = try client.parseKey("ctrl+b");
    try std.testing.expectEqualStrings("Ctrl+b %", chord(&storage, prefix, try client.parseKey("%")));
    try std.testing.expectEqualStrings("Shift+Left", chord(&storage, null, try client.parseKey("shift+left")));
}
