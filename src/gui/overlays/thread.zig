const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Canvas = @import("../chrome/Canvas.zig");

/// Paints the same thread header and composer exposed by the TUI projection.
/// Example: `try paint(canvas, pane.content, projection.threadView(pane.id).?);`.
pub fn paint(canvas: *Canvas, area: core.Rect, thread: client.ThreadView) !void {
    if (area.isEmpty()) {
        return;
    }

    const palette = canvas.theme.palette;
    try canvas.fill(area, palette.surface_dim);
    const header, const rest = area.splitTop(1);
    var storage: [256]u8 = undefined;
    const title = if (thread.agent) |agent|
        std.fmt.bufPrint(&storage, " {s} {s} · {s}", .{ agent.iconGlyph(), agent.displayName(), @tagName(agent.status) }) catch "Agent"
    else
        " no agent in this pane";
    try canvas.fill(header, palette.surface0);
    try canvas.text(header, .{ .text = title, .color = palette.accent, .bold = true });

    if (rest.isEmpty()) {
        return;
    }

    const body, const composer = rest.splitBottom(1);
    if (!body.isEmpty()) {
        const label = "transcript index pending";
        const width = @min(body.w, core.measure(label));
        try canvas.text(.{ .x = body.x + (body.w - width) / 2, .y = body.y + body.h / 2, .w = width, .h = 1 }, .{ .text = label, .color = palette.subtext0 });
    }

    try canvas.fill(composer, palette.surface0);
    try canvas.text(composer.splitLeft(2)[0], .{ .text = "> ", .color = palette.accent });
    try canvas.text(composer.splitLeft(2)[1], .{ .text = if (thread.composer.len == 0) "write to the agent" else thread.composer, .color = if (thread.composer.len == 0) palette.overlay1 else palette.text });
}
