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
