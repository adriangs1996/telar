const core = @import("telar-core");

modal: ?core.Rect = null,
history_metrics: ?@import("HistoryModalMetrics.zig") = null,
native_modal: ?@import("../../render/Rect.zig") = null,
notifications: @import("NotificationHits.zig") = .{},
/// Visible palette rows; empty for every other prompt.
palette: @import("PaletteHits.zig") = .{},
