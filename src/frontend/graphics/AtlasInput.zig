const RasterSize = @import("RasterSize.zig");
const IconsSlot = @import("IconsSlot.zig");
const AtlasInput = @This();

pixels: []u8,
raster_size: RasterSize,
atlas_width: u32,
slots: []const IconsSlot,
