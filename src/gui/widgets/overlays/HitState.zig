const core = @import("telar-core");
const HistoryModalMetrics = @import("HistoryModalMetrics.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const NotificationHits = @import("NotificationHits.zig");
const PaletteHits = @import("PaletteHits.zig");

modal: ?core.Rect = null,
history_metrics: ?HistoryModalMetrics = null,
native_modal: ?Rect = null,
notifications: NotificationHits = .{},
/// Visible palette rows; empty for every other prompt.
palette: PaletteHits = .{},
