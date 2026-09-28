//! A linear fade across already-shaped glyphs: full opacity up to `from`,
//! nothing from `to` on. Truncated labels end in this instead of an ellipsis.
const std = @import("std");
const Edge = @This();

from: f32,
to: f32,

/// Example: `glyph.a *= edge.at(glyph.x + glyph.width / 2);`
pub fn at(self: Edge, x: f32) f32 {
    const span = self.to - self.from;
    if (span == 0) {
        return if (x < self.to) 1 else 0;
    }

    return std.math.clamp((self.to - x) / span, 0, 1);
}

test "an edge keeps ink before it, removes ink past it and ramps between" {
    const edge: Edge = .{
        .from = 80,
        .to = 100,
    };

    try std.testing.expectEqual(@as(f32, 1), edge.at(10));
    try std.testing.expectEqual(@as(f32, 1), edge.at(80));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), edge.at(90), 0.0001);
    try std.testing.expectEqual(@as(f32, 0), edge.at(100));
    try std.testing.expectEqual(@as(f32, 0), edge.at(140));
}
