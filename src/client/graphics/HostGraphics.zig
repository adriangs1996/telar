/// Host-side image placement state owned by the presentation adapter. The
/// client tells it when physical placements no longer match the layout; the
/// adapter rebuilds them from retained images on its next presentation.
const HostGraphics = @This();

context: *anyopaque,
invalidate_placements: *const fn (*anyopaque) void,

/// Example: `client.host_graphics.invalidatePlacements();`.
pub fn invalidatePlacements(port: HostGraphics) void {
    port.invalidate_placements(port.context);
}
