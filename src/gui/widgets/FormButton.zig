//! A modal button using delivered pixel controls and owned prompt actions.
const Canvas = @import("Canvas.zig");
const Target = @import("interaction/Target.zig");
const Label = @import("Label.zig");
const FormButton = @This();

bounds: @import("../render/Rect.zig"),
text: []const u8,
label: ?[]const u8 = null,
action: Target.Action,
generation: u64,
namespace: u64,
primary: bool = false,
quiet: bool = false,
enabled: bool = true,
layer: u8 = 1,

/// Buttons activate on release inside their delivered bounds. Keyboard
/// equivalents remain with the form's editor, so clicking does not steal it.
/// Example: `try button.draw(canvas);`
pub fn draw(self: FormButton, canvas: *Canvas) !void {
    if (self.bounds.width <= 0 or self.bounds.height <= 0) {
        return;
    }

    const target = (Target{ .id = .{ .generation = self.generation }, .namespace = self.namespace, .bounds = self.bounds, .action = self.action, .layer = self.layer, .focusable = false, .enabled = self.enabled }).labelled(self.label orelse self.text);
    var hovered = false;
    var pressed = false;
    if (canvas.widgets) |state| {
        const id = try state.dispatcher.add(target);
        hovered = if (state.dispatcher.hovered) |hover| hover.eql(id) else false;
        pressed = if (state.dispatcher.captures[0]) |capture| capture.eql(id) else false;
    }

    const palette = canvas.theme.palette;
    const first = canvas.quads.items().len;
    if (!self.quiet or hovered or pressed) {
        try canvas.fillRoundedAt(self.bounds, .{ .color = if (self.primary) palette.accent else if (hovered or pressed) palette.surface1 else palette.surface0, .radius = canvas.chrome.px(7) });
    }

    var label: Label = .{ .text = self.text, .color = if (self.primary) canvas.covering(palette.surface_dim) else palette.text, .face = .sans, .size = .body, .bold = self.primary };
    if (pressed and self.enabled) {
        label.alpha = 0.8;
    }

    const width = @min(self.bounds.width, try canvas.measure(label));
    _ = try canvas.textAt(.{ .x = self.bounds.x + (self.bounds.width - width) / 2, .y = self.bounds.y, .width = width, .height = self.bounds.height }, label);
    if (!self.enabled) {
        canvas.quads.fadeFrom(first, 0.4);
    }
}
