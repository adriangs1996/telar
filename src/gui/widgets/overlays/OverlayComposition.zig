//! Borrowed layout inputs for one synchronous overlay composition.
const client = @import("telar-client");
const Canvas = @import("../Canvas.zig");
const HistoryExpansion = @import("HistoryExpansion.zig");
canvas: *Canvas,
projection: *const client.Projection,
router: ?*const client.key_router.Type = null,
scale: f32 = 1,
history_reveal: f32 = 1,
/// Whether the history panel shows that a replacement page is late.
history_loading: bool = false,
/// How open the selected history row is this frame.
history_expansion: HistoryExpansion = .{},
/// Opacity of the history inspector while it appears.
history_inspector_reveal: f32 = 1,
