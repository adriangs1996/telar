const ThemeType = @import("../../ui/Theme.zig");
const ClientTheme = @import("telar-client").Theme;
const Appearance = @This();

theme: ThemeType,
icons: ClientTheme = .unicode,
