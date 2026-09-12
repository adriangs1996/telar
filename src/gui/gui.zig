//! Native chrome adapter: paints the client's semantic projection on a GPU.
//! Shared client controllers own the session; native backends deliver input
//! and consume sealed cell frames without knowing the terminal protocol.

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
    _ = @import("tests/terminal.zig");
    _ = @import("TerminalMetrics.zig");
    _ = @import("NativeInput.zig");
    _ = GlyphAtlas;
    _ = QuadList;
    _ = cell_colors;
}
