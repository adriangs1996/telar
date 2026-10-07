const data = @import("model");
const client = @import("telar-client");
const Window = @import("telar-window");
config: client.GuiConfig,
theme: data.TerminalTheme = data.theme_support.default_theme.terminal,
viewport: Window.Viewport = .{ .width = 800, .height = 600, .scale = 1 },
