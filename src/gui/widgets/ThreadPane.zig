const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Canvas = @import("../chrome/Canvas.zig");

const ThreadPane = @This();

area: core.Rect,
thread: client.ThreadView,

/// Paints the thread header and composer captured during composition.
/// Example: `try thread_pane.draw(canvas);`
pub fn draw(widget: ThreadPane, canvas: *Canvas) !void {
    const area = widget.area;
    const thread = widget.thread;
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
        const label = "No conversation available";
        const width = @min(body.w, core.measure(label));
        try canvas.text(.{ .x = body.x + (body.w - width) / 2, .y = body.y + body.h / 2, .w = width, .h = 1 }, .{ .text = label, .color = palette.subtext0 });
    }

    try canvas.fill(composer, palette.surface0);
    try canvas.text(composer.splitLeft(2)[0], .{ .text = "> ", .color = palette.accent });
    try canvas.text(composer.splitLeft(2)[1], .{ .text = if (thread.composer.len == 0) "write to the agent" else thread.composer, .color = if (thread.composer.len == 0) palette.overlay1 else palette.text });
}
