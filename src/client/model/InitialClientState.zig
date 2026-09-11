const InitialClientState = @This();
const frontend_ui = @import("../layout/root.zig");
const bars_module = @import("../bars/root.zig");
const source_namespace = @import("types.zig");
const HostCapabilities = @import("HostCapabilities.zig");
pane_gaps: bool,
sidebar_width: u16 = frontend_ui.sidebar.default_width,
configuration_generation: u64 = 0,
bars: bars_module.Layout = .{},
host_size: source_namespace.schema.TerminalSize = .{ .cols = 80, .rows = 24 },
host_capabilities: HostCapabilities = .{},
