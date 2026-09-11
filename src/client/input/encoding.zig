const Encoding = @This();
const Key = @import("key_support.zig").Key;
const source_namespace = @import("encoding_support.zig");
modifier: u8,
kitty_flags: u5,
event_types: bool,
event: ?u2,
cursor_keys: bool,

pub fn init(key: Key, modes: source_namespace.Modes) Encoding {
    const event_types = modes.kitty_keyboard_flags & 0b00010 != 0;

    return .{
        .modifier = 1 + @as(u8, @intFromBool(key.mods.shift)) +
            2 * @as(u8, @intFromBool(key.mods.alt)) +
            4 * @as(u8, @intFromBool(key.mods.ctrl)),
        .kitty_flags = modes.kitty_keyboard_flags,
        .event_types = event_types,
        .event = if (event_types and key.phase != .press) @intFromEnum(key.phase) else null,
        .cursor_keys = modes.cursor_keys,
    };
}

pub fn reportsAllKeys(encoding: Encoding) bool {
    return encoding.kitty_flags & 0b01000 != 0;
}

pub fn usesKittyFor(encoding: Encoding, key: Key) bool {
    if (encoding.kitty_flags == 0) {
        return false;
    }

    return switch (key.code) {
        .char, .escape => true,
        .enter, .backspace, .tab => encoding.modifier != 1 or
            encoding.reportsAllKeys() or
            (encoding.event_types and key.kitty != null),
        else => false,
    };
}
