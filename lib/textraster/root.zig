//! Text rasterized into straight-alpha RGBA with FreeType and HarfBuzz:
//! shaping, measuring and drawing a line in a caller's font, and the
//! antialiased rounded fill the same surfaces use for backgrounds. The
//! rasterizer owns FreeType's mutable face and is single-threaded.

pub const Color = @import("Color.zig");
pub const Metrics = @import("Metrics.zig");
pub const Rasterizer = @import("Rasterizer.zig");
pub const Size = @import("Size.zig");
pub const Surface = @import("Surface.zig");
