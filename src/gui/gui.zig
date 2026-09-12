//! Native chrome adapter: paints the client's semantic projection on a GPU.
//! This slice only proves the paint contract: quads built in Zig, drawn by a
//! native backend that knows nothing about terminals.

pub const Application = @import("Application.zig");
pub const Color = @import("render/Color.zig");
pub const GlyphAtlas = @import("text/GlyphAtlas.zig");
pub const QuadList = @import("render/QuadList.zig");
pub const Rect = @import("render/Rect.zig");
pub const TextRun = @import("text/TextRun.zig");
pub const cell_colors = @import("render/cell_colors.zig");
pub const run = @import("run.zig").run;
pub const quad = @import("render/Quad.zig");

test {
    _ = Application;
    _ = GlyphAtlas;
    _ = QuadList;
    _ = cell_colors;
}
