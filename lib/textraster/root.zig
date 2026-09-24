//! Text rasterized into straight-alpha RGBA with FreeType and HarfBuzz:
//! shaping, measuring and drawing a line in a caller's font, and the
//! antialiased rounded fill the same surfaces use for backgrounds. The
//! rasterizer owns FreeType's mutable face and is single-threaded.

pub const Color = @import("Color.zig");
pub const Metrics = @import("Metrics.zig");
pub const Rasterizer = @import("Rasterizer.zig");
pub const Size = @import("Size.zig");
pub const Surface = @import("Surface.zig");
pub const rounded_rectangle = @import("rounded_rectangle.zig");

test {
    _ = @import("Color.zig");
    _ = @import("Metrics.zig");
    _ = @import("Rasterizer.zig");
    _ = @import("RasterizerPoint.zig");
    _ = @import("Size.zig");
    _ = @import("Surface.zig");
    _ = @import("rasterizer_support.zig");
    _ = @import("rounded_rectangle.zig");
}
