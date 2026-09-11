const Style = @import("Style.zig");
const std = @import("std");
/// One screen position.
///
/// The payload is a grapheme cluster, not a codepoint: `é` may be two
/// codepoints and a flag emoji is two more, and all of them occupy one or two
/// columns as a unit. Storing bytes inline keeps `Cell` comparable with a plain
/// equality check, which the diff runs once per position per frame.
const Cell = @This();

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
