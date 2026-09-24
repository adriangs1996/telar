//! What one screen position holds.
//!
//! Separate from the buffer because these types cross every boundary in the
//! library - the diff compares them, the blit produces them, the selection
//! reads them - while the buffer that stores them is an implementation detail
//! any of those could do without.

const std = @import("std");
const Style = @import("Style.zig");

pub const Color = @import("Color.zig").Color;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "the diff distinguishes attributes that used to be invisible to it" {
    // Before the flags were packed, `Style` carried bold/dim/reverse and
    // nothing else, so an italic run and an upright one compared equal and the
    // diff skipped the cell. Every attribute the emulator can set has to be
    // able to make two cells differ, or blitted panes render stale.
    const plain: Style = .{};
    inline for (.{ "italic", "blink", "strikethrough", "overline", "invisible" }) |name| {
        var flags: Style.Flags = .{};
        @field(flags, name) = true;
        try std.testing.expect(!plain.eql(.{ .flags = flags }));
    }
    try std.testing.expect(!plain.eql(.{ .flags = .{ .underline = .dotted } }));
    try std.testing.expect(!plain.eql(.{ .underline_color = .rgb(.{ 255, 0, 0 }) }));
}
