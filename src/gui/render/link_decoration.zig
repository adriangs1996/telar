//! Transient link affordances share the frame, without invalidating cell meshes.
const Canvas = @import("../chrome/Canvas.zig");
const Hit = @import("../input/LinkHit.zig");

/// Paints the hovered span and a clipped destination preview below pane output.
/// Example: `try link_decoration.paint(canvas, hit);`
pub fn paint(canvas: *Canvas, hit: *const Hit) !void {
    const pixels = canvas.rect(hit.area);
    const ink = canvas.theme.terminal.foreground;
    try canvas.quads.pushRect(.{ .x = pixels.x, .y = pixels.y + pixels.height - 2, .width = pixels.width, .height = 1 }, .rgb(ink[0], ink[1], ink[2]));
    var preview = hit.content.row(hit.content.h -| 1);
    preview.w = @min(preview.w, 100);
    if (preview.y == hit.area.y and hit.content.h > 1) {
        preview.y -= 1;
    }

    try canvas.fill(preview, canvas.theme.palette.surface0);
    try canvas.text(preview, .{ .text = hit.match.target.uri(), .color = canvas.theme.palette.text });
}
