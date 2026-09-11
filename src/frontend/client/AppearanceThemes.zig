const AppearanceThemes = @This();
const theme_capability = @import("../ui/theme_support.zig");
light: ?theme_capability.Theme = null,
dark: ?theme_capability.Theme = null,
