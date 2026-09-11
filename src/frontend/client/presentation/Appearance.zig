const Appearance = @This();
const theme_mod = @import("../../ui/root.zig").theme;
const ui = @import("../../ui/root.zig");
theme: theme_mod.Theme,
icons: ui.icons.Theme = .unicode,
