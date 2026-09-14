//! A concrete single-field prompt selected during scene composition.
const client = @import("telar-client");
const core = @import("telar-core");
const Canvas = @import("../Canvas.zig");
const Modal = @import("Modal.zig");
const TextField = @import("../TextField.zig");
const NamePrompt = @This();

area: core.Rect,
prompt: *const client.Prompt,
title: []const u8,

/// Example: `try prompt.draw(canvas);`
pub fn draw(widget: NamePrompt, canvas: *Canvas) !void {
    const modal: Modal = .{ .area = widget.area, .title = widget.title };
    const prompt = widget.prompt.*;
    try modal.draw(canvas);

    const content = modal.content();
    try TextField.fromPrompt(&prompt, canvas.rect(content.row(if (content.h > 2) 1 else 0)), .name).draw(canvas);

    if (content.h > 2) {
        try canvas.text(content.row(content.h - 1), .{ .text = "Enter confirm  Esc cancel", .color = canvas.theme.palette.subtext0 });
    }
}
