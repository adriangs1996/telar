//! Native chrome adapter: paints the client's semantic projection on a GPU.
//! Shared client controllers own the session; native backends deliver input
//! and consume sealed cell frames without knowing the terminal protocol.

const run_module = @import("run.zig");
pub const GuiAdapter = @import("GuiAdapter.zig");
pub const GlyphAtlas = @import("text/GlyphAtlas.zig");
pub const TextRun = @import("text/TextRun.zig");
pub const cell_colors = @import("render/cell_colors.zig");
pub const run = run_module.run;
pub const Canvas = @import("widgets/Canvas.zig");
pub const GenericWidgetList = @import("widgets/GenericWidgetList.zig").Type;
