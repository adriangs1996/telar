const PresentContext = @This();
const source_namespace = @import("terminal_browser_pane.zig");
const Emulator = @import("Emulator.zig");
const GraphicsMirror = @import("GraphicsMirror.zig");
const FrameGeometry = @import("FrameGeometry.zig");
screen: *source_namespace.term.Screen,
writer: *source_namespace.Io.Writer,
emulator: *Emulator,
mirror: *GraphicsMirror,
graphics_store: *source_namespace.kitty.Store,
model: *source_namespace.multiplexer.Model,
frame: FrameGeometry,
capabilities: *const source_namespace.HostCapabilities,
