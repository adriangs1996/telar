const client = @import("telar-client");
const Viewport = @import("../native/Viewport.zig");
config: client.GuiConfig,
theme: client.TerminalTheme = client.theme_support.default_theme.terminal,
viewport: Viewport.Viewport = .{ .width = 800, .height = 600, .scale = 1 },
