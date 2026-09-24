//! Pixel geometry and the primitives a renderer draws: rectangles, colors,
//! quads, and a flex-style layout that places items along one axis.

pub const Color = @import("Color.zig");
pub const Item = @import("Item.zig");
pub const Layout = @import("Layout.zig");
pub const Quad = @import("Quad.zig");
pub const Rect = @import("Rect.zig");
pub const RoundedRect = @import("RoundedRect.zig");
pub const SpriteQuad = @import("SpriteQuad.zig");
pub const alignment = @import("alignment.zig");

test {
    _ = @import("Color.zig");
    _ = @import("Insets.zig");
    _ = @import("Item.zig");
    _ = @import("Layout.zig");
    _ = @import("Quad.zig");
    _ = @import("Rect.zig");
    _ = @import("RoundedRect.zig");
    _ = @import("SpriteQuad.zig");
    _ = @import("alignment.zig");
    _ = @import("length.zig");
}
