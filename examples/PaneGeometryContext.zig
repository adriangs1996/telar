const PaneGeometryContext = @This();
const source_namespace = @import("terminal_browser_pane.zig");
const Emulator = @import("Emulator.zig");
const FrameGeometry = @import("FrameGeometry.zig");
session: *source_namespace.pty.Session,
emulator: *Emulator,
model: *source_namespace.multiplexer.Model,
graphics_store: *source_namespace.kitty.Store,
frame: FrameGeometry,
capabilities: *const source_namespace.HostCapabilities,
