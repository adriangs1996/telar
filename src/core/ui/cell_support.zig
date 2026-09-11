//! What one screen position holds.
//!
//! Separate from the buffer because these types cross every boundary in the
//! library - the diff compares them, the blit produces them, the selection
//! reads them - while the buffer that stores them is an implementation detail
//! any of those could do without.

const std = @import("std");
const Style = @import("Style.zig");

pub const Color = union(enum) {
    default,
    indexed: u8,
    rgb: [3]u8,

    pub fn eql(a: Color, b: Color) bool {
        return switch (a) {
            .default => b == .default,
            .indexed => |v| b == .indexed and b.indexed == v,
            .rgb => |v| b == .rgb and std.mem.eql(u8, &v, &b.rgb),
        };
    }
};

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
    try std.testing.expect(!plain.eql(.{ .underline_color = .{ .rgb = .{ 255, 0, 0 } } }));
}
