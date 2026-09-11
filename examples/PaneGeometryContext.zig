const SessionType = @import("telar-backend").Session;
const Emulator = @import("Emulator.zig");
const MultiplexerModel = @import("telar-client").MultiplexerModel;
const StoreType = @import("telar-frontend").Store;
const FrameGeometry = @import("FrameGeometry.zig");
const HostCapabilitiesType = @import("telar-client").HostCapabilities;
const PaneGeometryContext = @This();

session: *SessionType,
emulator: *Emulator,
model: *MultiplexerModel,
graphics_store: *StoreType,
frame: FrameGeometry,
capabilities: *const HostCapabilitiesType,
