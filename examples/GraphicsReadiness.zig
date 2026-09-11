const HostCapabilitiesType = @import("telar-client").HostCapabilities;
const Emulator = @import("Emulator.zig");
const GraphicsMirror = @import("GraphicsMirror.zig");
const StoreType = @import("telar-frontend").Store;
const GraphicsReadiness = @This();

capabilities: *const HostCapabilitiesType,
emulator: *const Emulator,
mirror: *const GraphicsMirror,
store: *const StoreType,
