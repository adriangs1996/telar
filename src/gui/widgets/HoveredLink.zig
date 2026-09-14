//! Transient link affordances share the frame, without invalidating cell meshes.
const Canvas = @import("../chrome/Canvas.zig");
const Hit = @import("../input/LinkHit.zig");
const client = @import("telar-client");
const LinkRegions = @import("../render/LinkRegions.zig");

const HoveredLink = @This();

hit: *const Hit,
pane: *const client.Pane,

/// Paints the captured link span and its clipped destination preview.
/// Example: `try hovered_link.draw(canvas);`
pub fn draw(widget: HoveredLink, canvas: *Canvas) !void {
    const hit = widget.hit;
    const pane = widget.pane;
    const ink = canvas.theme.terminal.foreground;
    var regions = LinkRegions.init(hit, pane);
    while (regions.next()) |area| {
        const pixels = canvas.rect(area);
        try canvas.quads.pushRect(.{ .x = pixels.x, .y = pixels.y + pixels.height - 2, .width = pixels.width, .height = 1 }, .rgb(ink[0], ink[1], ink[2]));
    }

    const preview = hit.previewArea() orelse return;
    try canvas.fill(preview, canvas.theme.palette.surface0);
    try canvas.text(preview, .{ .text = hit.match.target.uri(), .color = canvas.theme.palette.text });
}
