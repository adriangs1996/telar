const Input = @This();
const source_namespace = @import("fullscreen_tabs.zig");
const theme = @import("../ui/root.zig").theme;
area: source_namespace.ui.Rect,
names: []const []const u8,
focused: usize,
palette: *const theme.Palette,
