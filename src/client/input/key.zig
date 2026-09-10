//! Owned semantic keys shared by host decoding, routing and child encoding.

const std = @import("std");

pub const Key = struct {
    code: Code,
    mods: Mods = .{},
    phase: Phase = .press,
    physical: ?Physical = null,
    kitty: ?KittyCodepoints = null,

    pub const Phase = enum(u2) { press = 1, repeat = 2, release = 3 };

    pub const Physical = struct {
        value: u32,

        pub fn eql(a: Physical, b: Physical) bool {
            return a.value == b.value;
        }
    };

    // Retained codepoint identities needed when encoding the child's active
    // keyboard protocol. They contain no borrowed host-input bytes.
    pub const KittyCodepoints = struct {
        primary: u32,
        shifted: ?u32 = null,
        base: ?u32 = null,
    };

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

    pub const Mods = packed struct(u3) {
        shift: bool = false,
        alt: bool = false,
        ctrl: bool = false,
    };

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
};

pub const Char = struct {
    bytes: [4]u8 = @splat(0),
    len: u8 = 0,

    /// Copies one decoded UTF-8 scalar into the event. Example: const c = Char.init("ñ");
    pub fn init(text: []const u8) Char {
        var char: Char = .{ .len = @intCast(@min(text.len, 4)) };
        @memcpy(char.bytes[0..char.len], text[0..char.len]);
        return char;
    }

    pub fn slice(char: *const Char) []const u8 {
        return char.bytes[0..char.len];
    }

    pub fn eql(char: *const Char, text: []const u8) bool {
        return std.mem.eql(u8, char.slice(), text);
    }
};

pub const Mouse = struct {
    x: u16,
    y: u16,
    raw_x: u32 = 0,
    raw_y: u32 = 0,
    kind: Kind,
    button: u8 = 0,

    pub const Kind = enum { press, release, drag, scroll_up, scroll_down, move };
};

test "semantic key owns its scalar after the input buffer changes" {
    var bytes = [_]u8{ 0xc3, 0xb1 };
    const key = Key.plain(.{ .char = Char.init(&bytes) });
    @memset(&bytes, 0);
    try std.testing.expectEqualStrings("ñ", key.code.char.slice());
}
