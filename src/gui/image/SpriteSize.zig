//! The sides a sprite is drawn at, in logical chrome pixels. A favicon is
//! stored once per size so every view samples one texel per pixel; the
//! provider marks are stored at `large` and only shrink.
const std = @import("std");

pub const SpriteSize = enum {
    /// The agent card's project icon and the top bar's workspace marks.
    small,
    /// The workspace list's rows.
    medium,
    /// The workspace rail's marks.
    large,

    pub const count = @typeInfo(SpriteSize).@"enum".fields.len;
    pub const all = std.enums.values(SpriteSize);

    /// The side in logical chrome pixels.
    /// Example: `const side = @round(canvas.chrome.px(SpriteSize.medium.logical()));`
    pub fn logical(self: SpriteSize) f32 {
        return switch (self) {
            .small => 14,
            .medium => 18,
            .large => 20,
        };
    }
};

test "sizes grow in declaration order" {
    for (SpriteSize.all[1..], SpriteSize.all[0 .. SpriteSize.count - 1]) |size, smaller| {
        try std.testing.expect(size.logical() > smaller.logical());
    }
}
