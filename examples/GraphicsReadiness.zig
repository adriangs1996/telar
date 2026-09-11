const GraphicsReadiness = @This();
const source_namespace = @import("terminal_browser_pane.zig");
const Emulator = @import("Emulator.zig");
const GraphicsMirror = @import("GraphicsMirror.zig");
capabilities: *const source_namespace.HostCapabilities,
emulator: *const Emulator,
mirror: *const GraphicsMirror,
store: *const source_namespace.kitty.Store,
