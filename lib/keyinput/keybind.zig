//! Ordering over keys and key sequences, the order a keymap sorts and
//! searches its bindings by.
const std = @import("std");
const Key = @import("Key.zig");

/// The number of leading keys two sequences share.
///
/// ```zig
/// const shared = keybind.commonPrefix(binding.slice(), pending);
/// ```
pub fn commonPrefix(a: []const Key, b: []const Key) usize {
    const limit = @min(a.len, b.len);
    var index: usize = 0;
    while (index < limit and keyOrder(a[index], b[index]) == .eq) : (index += 1) {}
    return index;
}

/// Orders sequences key by key, a shorter prefix first.
///
/// ```zig
/// std.mem.sort(Binding, bindings, {}, lessThan); // lessThan calls sequenceOrder
/// ```
pub fn sequenceOrder(a: []const Key, b: []const Key) std.math.Order {
    const limit = @min(a.len, b.len);
    for (0..limit) |index| {
        const order = keyOrder(a[index], b[index]);
        if (order != .eq) {
            return order;
        }
    }

    return std.math.order(a.len, b.len);
}

/// Orders keys by modifiers, then code, then character text.
///
/// ```zig
/// if (keybind.keyOrder(pressed, bound) == .eq) fire();
/// ```
pub fn keyOrder(a: Key, b: Key) std.math.Order {
    if (a.mods.super != b.mods.super) {
        return std.math.order(@intFromBool(a.mods.super), @intFromBool(b.mods.super));
    }

    if (a.mods.ctrl != b.mods.ctrl) {
        return std.math.order(@intFromBool(a.mods.ctrl), @intFromBool(b.mods.ctrl));
    }

    if (a.mods.alt != b.mods.alt) {
        return std.math.order(@intFromBool(a.mods.alt), @intFromBool(b.mods.alt));
    }

    if (a.mods.shift != b.mods.shift) {
        return std.math.order(@intFromBool(a.mods.shift), @intFromBool(b.mods.shift));
    }

    const a_tag = std.meta.activeTag(a.code);
    const b_tag = std.meta.activeTag(b.code);
    const tag_order = std.math.order(@intFromEnum(a_tag), @intFromEnum(b_tag));
    if (tag_order != .eq or a_tag != .char) {
        return tag_order;
    }

    const a_char = a.code.char;
    const b_char = b.code.char;
    return std.mem.order(u8, a_char.slice(), b_char.slice());
}

/// True for Escape without modifiers.
///
/// ```zig
/// if (keybind.isPlainEscape(key)) cancel();
/// ```
pub fn isPlainEscape(key: Key) bool {
    if (key.mods.ctrl or key.mods.alt or key.mods.shift or key.mods.super) {
        return false;
    }

    return switch (key.code) {
        .escape => true,
        else => false,
    };
}
