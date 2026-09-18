//! One visible Markdown link fragment with owned source coordinates.
const std = @import("std");
const Canvas = @import("Canvas.zig");
const Rect = @import("../render/Rect.zig");
const Label = @import("Label.zig");
const Button = @This();

bounds: Rect,
viewport: Rect,
control: @import("interaction/MessageLinkControl.zig"),
label: Label,
advance: f32,

/// Paints linked ink and publishes its visible bounds without retaining text.
/// Example: `try fragment.draw(canvas);`
pub fn draw(button: Button, canvas: *Canvas) !void {
    var label = button.label;
    label.text = std.mem.trim(u8, label.text, " \t\r\n");
    if (label.text.len == 0) {
        return;
    }

    const leading = @intFromPtr(label.text.ptr) - @intFromPtr(button.label.text.ptr);
    var prefix = button.label;
    prefix.text = prefix.text[0..leading];
    const inset = if (leading == 0) 0 else try canvas.measure(prefix);
    const advance = if (label.text.len == button.label.text.len) button.advance else try canvas.measure(label);
    const width = @min(advance, @max(0, button.bounds.width - inset));
    if (width <= 0) {
        return;
    }

    const area: Rect = .{ .x = button.bounds.x + inset, .y = button.bounds.y, .width = width, .height = button.bounds.height };
    label.color = canvas.theme.palette.accent;
    label.underline = true;
    var paint_area = area;
    paint_area.width = @min(advance + 1, @max(0, button.bounds.width - inset));
    _ = try canvas.textAt(paint_area, label);
    const state = canvas.widgets orelse return;
    const left = @max(area.x, button.viewport.x);
    const top = @max(area.y, button.viewport.y);
    const right = @min(area.x + area.width, button.viewport.x + button.viewport.width);
    const bottom = @min(area.y + area.height, button.viewport.y + button.viewport.height);
    if (right <= left or bottom <= top) {
        return;
    }

    var control = button.control;
    control.fragment_offset += @intCast(leading);
    _ = try state.dispatcher.addMessageLink((@import("interaction/Target.zig"){ .id = .{ .generation = control.owner.attachment_generation }, .bounds = .{ .x = left, .y = top, .width = right - left, .height = bottom - top }, .action = .{ .message_link = control }, .focusable = false, .role = 4 }).labelled(label.text));
}
