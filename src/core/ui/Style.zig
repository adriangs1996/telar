const cell_support = @import("cell_support.zig");
const Style = @This();

fg: cell_support.Color = .default,
bg: cell_support.Color = .default,
/// Separate from `fg` since SGR 58. A terminal that does not understand it
/// underlines in the foreground colour, which is the pre-58 behaviour.
underline_color: cell_support.Color = .default,
flags: Flags = .{},

pub const Flags = @import("Flags.zig").Flags;

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
