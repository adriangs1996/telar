//! Transient link affordances share the frame, without invalidating cell
//! meshes: an accent underline over every visible span of the hovered link
//! and the tooltip that names its destination.
const data = @import("model");
const Canvas = @import("Canvas.zig");
const Hit = @import("../input/LinkHit.zig");
const LinkRegions = @import("../render/LinkRegions.zig");
const LinkTooltip = @import("LinkTooltip.zig");

const HoveredLink = @This();

hit: *const Hit,
pane: *const data.Pane,

/// Paints the captured link span and its destination card.
/// Example: `try hovered_link.draw(canvas);`
pub fn draw(self: HoveredLink, canvas: *Canvas) !void {
    const hit = self.hit;
    var regions = LinkRegions.init(hit, self.pane);
    while (regions.next()) |area| {
        const pixels = canvas.rect(area);
        try canvas.fillAt(.{ .x = pixels.x, .y = pixels.y + pixels.height - 2, .width = pixels.width, .height = 1 }, canvas.theme.palette.accent);
    }

    try (LinkTooltip{ .hit = hit }).draw(canvas);
}
