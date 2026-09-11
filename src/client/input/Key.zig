const PhysicalType = @import("Physical.zig");
const KittyCodepointsType = @import("KittyCodepoints.zig");
const Char = @import("Char.zig");
const std = @import("std");
const Key = @This();

code: Code,
mods: Mods = .{},
phase: Phase = .press,
physical: ?PhysicalType = null,
kitty: ?KittyCodepointsType = null,

pub const Phase = enum(u2) { press = 1, repeat = 2, release = 3 };

pub const Physical = @import("Physical.zig");

// Retained codepoint identities needed when encoding the child's active
// keyboard protocol. They contain no borrowed host-input bytes.
pub const KittyCodepoints = @import("KittyCodepoints.zig");

pub const Code = union(enum) {
    char: Char,
    up,
    down,
    left,
    right,
    home,
    end,
    delete,
    page_up,
    page_down,
    enter,
    escape,
    backspace,
    tab,
    back_tab,
};

pub const Mods = @import("Mods.zig").Mods;

pub fn plain(code: Code) Key {
    return .{ .code = code };
}

/// Matches a case-insensitive Ctrl chord. Example: if (key.isCtrl('c')) cancel();
pub fn isCtrl(key: Key, letter: u8) bool {
    if (!key.mods.ctrl) {
        return false;
    }

    return switch (key.code) {
        .char => |char| char.len == 1 and std.ascii.toLower(char.bytes[0]) == letter,
        else => false,
    };
}
