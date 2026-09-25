const PixelSize = @import("PixelSize.zig");
const HostCapabilitySupport = @import("HostCapabilitySupport.zig").HostCapabilitySupport;

pub const HostCapabilityObservation = union(enum) {
    images: HostCapabilitySupport,
    window_pixels: PixelSize,
    cell_pixels: PixelSize,
    pointer_pixels: HostCapabilitySupport,
    foreground: struct { r: u8, g: u8, b: u8 },
    background: struct { r: u8, g: u8, b: u8 },
};
