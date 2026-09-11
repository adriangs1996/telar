const AtlasInput = @This();
const RasterSize = @import("RasterSize.zig");
const Slot = @import("IconsSlot.zig");
pixels: []u8,
raster_size: RasterSize,
atlas_width: u32,
slots: []const Slot,
