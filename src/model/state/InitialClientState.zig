const data = @import("../model.zig");
const core = @import("telar-core");
const LayoutType = @import("../bars/BarLayout.zig");
const Config = @import("Config.zig");
const InitialClientState = @This();

pane_gaps: bool,
sidebar_width: u16 = data.sidebar.default_width,
configuration_generation: u64 = 0,
bars: LayoutType = .{},
host_size: core.TerminalSize = .{ .cols = 80, .rows = 24 },
host_capabilities: data.HostCapabilities = .{},
config: Config = .{},
theme: data.ColorTheme = data.theme_support.default_theme,
icon_theme: data.icons.Theme = .unicode,
/// Borrowed only during initialization; copied into the model.
window_title: []const u8 = "",
