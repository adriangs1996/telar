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
    _ = @import("tests/links.zig");
    _ = @import("tests/link_metadata.zig");
    _ = @import("tests/link_regressions.zig");
    _ = Application;
    _ = @import("WindowIdentity.zig");
    _ = @import("tests/terminal.zig");
    _ = @import("tests/configuration.zig");
    _ = @import("tests/font_thicken.zig");
    _ = @import("tests/braille.zig");
    _ = @import("tests/box_drawing.zig");
    _ = @import("tests/italic.zig");
    _ = @import("tests/navigation.zig");
    _ = @import("tests/chrome.zig");
    _ = @import("tests/composition_budget.zig");
    _ = @import("tests/overlays.zig");
    _ = @import("tests/scene.zig");
    _ = @import("tests/visual_language.zig");
    _ = @import("TerminalMetrics.zig");
    _ = @import("NativeInput.zig");
    _ = @import("CursorClock.zig");
    _ = GlyphAtlas;
    _ = QuadList;
    _ = cell_colors;
}
