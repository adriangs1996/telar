//! One visible Markdown link fragment with owned source coordinates.
const std = @import("std");
const Canvas = @import("Canvas.zig");
const Rect = @import("../render/Rect.zig");
const Label = @import("Label.zig");
const MessageLinkControl = @import("interaction/MessageLinkControl.zig");
const Target = @import("interaction/Target.zig");
const Button = @This();

bounds: Rect,
viewport: Rect,
control: MessageLinkControl,
label: Label,
advance: f32,

/// Paints linked ink and publishes its visible bounds without retaining text.
/// Example: `try fragment.draw(canvas);`
pub fn draw(self: Button, canvas: *Canvas) !void {
    var label = self.label;
    label.text = std.mem.trim(u8, label.text, " \t\r\n");
    if (label.text.len == 0) {
        return;
    }

    const leading = @intFromPtr(label.text.ptr) - @intFromPtr(self.label.text.ptr);
    var prefix = self.label;
    prefix.text = prefix.text[0..leading];
    const inset = if (leading == 0) 0 else try canvas.measure(prefix);
    const advance = if (label.text.len == self.label.text.len) self.advance else try canvas.measure(label);
    const width = @min(advance, @max(0, self.bounds.width - inset));
    if (width <= 0) {
        return;
    }

    const area: Rect = .{ .x = self.bounds.x + inset, .y = self.bounds.y, .width = width, .height = self.bounds.height };
    label.color = canvas.theme.palette.accent;
    label.underline = true;
    var paint_area = area;
    paint_area.width = @min(advance + 1, @max(0, self.bounds.width - inset));
    _ = try canvas.textAt(paint_area, label);
    const state = canvas.widgets orelse return;
    const left = @max(area.x, self.viewport.x);
    const top = @max(area.y, self.viewport.y);
    const right = @min(area.x + area.width, self.viewport.x + self.viewport.width);
    const bottom = @min(area.y + area.height, self.viewport.y + self.viewport.height);
    if (right <= left or bottom <= top) {
        return;
    }

    var control = self.control;
    control.fragment_offset += @intCast(leading);
    _ = try state.dispatcher.addMessageLink((Target{ .id = .{ .generation = control.owner.attachment_generation }, .bounds = .{ .x = left, .y = top, .width = right - left, .height = bottom - top }, .action = .{ .message_link = control }, .focusable = false, .role = 4 }).labelled(label.text));
}
