//! What one frame paints of the history selection: the selected row `open`
//! between 0 and 1, and the row the selection left while it closes.
const HistoryPosition = @import("HistoryPosition.zig");

open: f32 = 1,
leaving: ?HistoryPosition = null,
leaving_open: f32 = 0,
