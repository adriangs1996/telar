const core = @import("telar-core");

modal: ?core.Rect = null,
notifications: @import("Notifications.zig") = .{},
/// Visible palette rows; empty for every other prompt.
palette: @import("PaletteHits.zig") = .{},
