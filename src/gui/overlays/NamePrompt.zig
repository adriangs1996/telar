//! A concrete single-field prompt selected during scene composition.
const client = @import("telar-client");
const core = @import("telar-core");
const Canvas = @import("../chrome/Canvas.zig");
const Modal = @import("Modal.zig");
const NamePrompt = @This();

area: core.Rect,
prompt: *const client.Prompt,
title: []const u8,

/// Example: `try prompt.draw(canvas);`
pub fn draw(widget: NamePrompt, canvas: *Canvas) !void {
    const modal: Modal = .{ .canvas = canvas, .area = widget.area };
    const prompt = widget.prompt.*;
    try modal.frame(widget.title);

    const content = modal.content();
    try modal.field(content.row(if (content.h > 2) 1 else 0), prompt);

    if (content.h > 2) {
        try modal.line(content.h - 1, .{ .text = "Enter confirm  Esc cancel", .color = modal.canvas.theme.palette.subtext0 });
    }
}
