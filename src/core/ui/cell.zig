//! What one screen position holds.
//!
//! Separate from the buffer because these types cross every boundary in the
//! library - the diff compares them, the blit produces them, the selection
//! reads them - while the buffer that stores them is an implementation detail
//! any of those could do without.

const std = @import("std");

pub const Color = union(enum) {
    default,
    indexed: u8,
    rgb: [3]u8,

    fn eql(a: Color, b: Color) bool {
        return switch (a) {
            .default => b == .default,
            .indexed => |v| b == .indexed and b.indexed == v,
            .rgb => |v| b == .rgb and std.mem.eql(u8, &v, &b.rgb),
        };
    }
};

pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    /// Separate from `fg` since SGR 58. A terminal that does not understand it
    /// underlines in the foreground colour, which is the pre-58 behaviour.
    underline_color: Color = .default,
    flags: Flags = .{},

    /// The on/off attributes, laid out bit for bit like the emulator's.
    ///
    /// The layout is copied rather than approximated so that blitting a pane's
    /// styles is a `@bitCast` instead of a field by field translation, and so
    /// that a cell we draw and a cell the emulator drew can never disagree
    /// about what "bold" means. The test that pins the two layouts together
    /// lives next to the bitcast, in `blit.zig`.
    pub const Flags = packed struct(u16) {
        bold: bool = false,
        italic: bool = false,
        faint: bool = false,
        blink: bool = false,
        inverse: bool = false,
        invisible: bool = false,
        strikethrough: bool = false,
        overline: bool = false,
        underline: Underline = .none,
        _padding: u5 = 0,
    };

    pub const Underline = enum(u3) {
        none = 0,
        single = 1,
        double = 2,
        curly = 3,
        dotted = 4,
        dashed = 5,
    };

    /// Runs once per position per frame in the diff, so it is the hottest
    /// comparison in the renderer. Packing the attributes turned five branches
    /// into one integer compare.
    pub fn eql(a: Style, b: Style) bool {
        return @as(u16, @bitCast(a.flags)) == @as(u16, @bitCast(b.flags)) and
            a.fg.eql(b.fg) and a.bg.eql(b.bg) and
            a.underline_color.eql(b.underline_color);
    }
};

/// One screen position.
///
/// The payload is a grapheme cluster, not a codepoint: `é` may be two
/// codepoints and a flag emoji is two more, and all of them occupy one or two
/// columns as a unit. Storing bytes inline keeps `Cell` comparable with a plain
/// equality check, which the diff runs once per position per frame.
pub const Cell = struct {
    /// Enough for a base character with a few combining marks. Longer clusters
    /// - family emoji with several zero width joiners - are truncated, which
    /// costs a rendering artefact rather than a corrupted grid.
    pub const max_bytes = 16;

    bytes: [max_bytes]u8 = [_]u8{' '} ++ [_]u8{0} ** (max_bytes - 1),
    len: u8 = 1,
    /// 0 marks the second half of a wide character. Nothing is emitted for it;
    /// the terminal's own cursor advance covers it.
    width: u8 = 1,
    style: Style = .{},

    pub fn text(c: *const Cell) []const u8 {
        return c.bytes[0..c.len];
    }

    /// The diff calls this once per position per frame, so it is the hottest
    /// comparison in the renderer.
    pub fn eqlPublic(a: *const Cell, b: *const Cell) bool {
        return a.eql(b);
    }

    fn eql(a: *const Cell, b: *const Cell) bool {
        return a.len == b.len and a.width == b.width and
            std.mem.eql(u8, a.text(), b.text()) and a.style.eql(b.style);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the diff distinguishes attributes that used to be invisible to it" {
    // Before the flags were packed, `Style` carried bold/dim/reverse and
    // nothing else, so an italic run and an upright one compared equal and the
    // diff skipped the cell. Every attribute the emulator can set has to be
    // able to make two cells differ, or blitted panes render stale.
    const plain: Style = .{};
    inline for (.{ "italic", "blink", "strikethrough", "overline", "invisible" }) |name| {
        var flags: Style.Flags = .{};
        @field(flags, name) = true;
        try testing.expect(!plain.eql(.{ .flags = flags }));
    }
    try testing.expect(!plain.eql(.{ .flags = .{ .underline = .dotted } }));
    try testing.expect(!plain.eql(.{ .underline_color = .{ .rgb = .{ 255, 0, 0 } } }));
}
