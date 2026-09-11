const KeyType = @import("Key.zig");
const chord = @import("chord.zig");

const std = @import("std");

pub const Key = @import("Key.zig");

pub const parseKey = chord.parseKey;

pub const Control = enum {
    continue_routing,
    stop,
};

pub const default_escape_timeout_ns: u64 = 25 * std.time.ns_per_ms;

pub const default_sequence_timeout_ns: u64 = 1000 * std.time.ns_per_ms;

pub const default_prefix = chord.parseKey("ctrl+b") catch unreachable;

pub const max_physical_leases = 64;

pub const RepeatPolicy = @import("RepeatPolicy.zig");

pub fn commonPrefix(a: []const KeyType, b: []const KeyType) usize {
    const limit = @min(a.len, b.len);
    var index: usize = 0;
    while (index < limit and keyOrder(a[index], b[index]) == .eq) : (index += 1) {}
    return index;
}

pub fn sequenceOrder(a: []const KeyType, b: []const KeyType) std.math.Order {
    const limit = @min(a.len, b.len);
    for (0..limit) |index| {
        const order = keyOrder(a[index], b[index]);
        if (order != .eq) {
            return order;
        }
    }
    return std.math.order(a.len, b.len);
}

pub fn keyOrder(a: KeyType, b: KeyType) std.math.Order {
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

pub fn isPlainEscape(key: KeyType) bool {
    if (key.mods.ctrl or key.mods.alt or key.mods.shift) {
        return false;
    }
    return switch (key.code) {
        .escape => true,
        else => false,
    };
}

pub const RouterLimits = @import("RouterLimits.zig");
