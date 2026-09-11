const sidebar_module = @import("../layout/sidebar.zig");
const LayoutType = @import("../bars/BarLayout.zig");
const TerminalSizeType = @import("telar-core").TerminalSize;
const HostCapabilities = @import("HostCapabilities.zig");
const InitialClientState = @This();

pane_gaps: bool,
sidebar_width: u16 = sidebar_module.default_width,
configuration_generation: u64 = 0,
bars: LayoutType = .{},
host_size: TerminalSizeType = .{ .cols = 80, .rows = 24 },
host_capabilities: HostCapabilities = .{},
