const Style = @This();
const source_namespace = @import("cell_support.zig");
fg: source_namespace.Color = .default,
bg: source_namespace.Color = .default,
/// Separate from `fg` since SGR 58. A terminal that does not understand it
/// underlines in the foreground colour, which is the pre-58 behaviour.
underline_color: source_namespace.Color = .default,
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
