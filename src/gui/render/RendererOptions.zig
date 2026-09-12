config: @import("telar-client").GuiConfig,
theme: @import("telar-client").TerminalTheme = @import("telar-client").theme_support.default_theme.terminal,
viewport: @import("../native/Viewport.zig").Viewport = .{ .width = 800, .height = 600, .scale = 1 },
