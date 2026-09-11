const ScreenType = @import("telar-frontend").Screen;
const std = @import("std");
const Emulator = @import("Emulator.zig");
const GraphicsMirror = @import("GraphicsMirror.zig");
const StoreType = @import("telar-frontend").Store;
const MultiplexerModel = @import("telar-client").MultiplexerModel;
const FrameGeometry = @import("FrameGeometry.zig");
const HostCapabilitiesType = @import("telar-client").HostCapabilities;
const PresentContext = @This();

screen: *ScreenType,
writer: *std.Io.Writer,
emulator: *Emulator,
mirror: *GraphicsMirror,
graphics_store: *StoreType,
model: *MultiplexerModel,
frame: FrameGeometry,
capabilities: *const HostCapabilitiesType,
