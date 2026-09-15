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

/// Buttons activate on release inside their delivered bounds. Keyboard
/// equivalents remain with the form's editor, so clicking does not steal it.
/// Example: `try button.draw(canvas);`
pub fn draw(button: FormButton, canvas: *Canvas) !void {
    if (button.bounds.width <= 0 or button.bounds.height <= 0) {
        return;
    }

    const target = (Target{ .id = .{ .generation = button.generation }, .namespace = button.namespace, .bounds = button.bounds, .action = button.action, .layer = 1, .focusable = false, .enabled = button.enabled }).labelled(button.label orelse button.text);
    var hovered = false;
    var pressed = false;
    if (canvas.widgets) |state| {
        const id = try state.dispatcher.add(target);
        hovered = if (state.dispatcher.hovered) |hover| hover.eql(id) else false;
        pressed = if (state.dispatcher.captures[0]) |capture| capture.eql(id) else false;
    }

    const palette = canvas.theme.palette;
    const first = canvas.quads.items().len;
    if (!button.quiet or hovered or pressed) {
        try canvas.fillRoundedAt(button.bounds, .{ .color = if (button.primary) palette.accent else if (hovered or pressed) palette.surface1 else palette.surface0, .radius = canvas.chrome.px(7) });
    }

    var label: Label = .{ .text = button.text, .color = if (button.primary) canvas.covering(palette.surface_dim) else palette.text, .face = .sans, .size = .body, .bold = button.primary };
    if (pressed and button.enabled) {
        label.alpha = 0.8;
    }

    const width = @min(button.bounds.width, try canvas.measure(label));
    _ = try canvas.textAt(.{ .x = button.bounds.x + (button.bounds.width - width) / 2, .y = button.bounds.y, .width = width, .height = button.bounds.height }, label);
    if (!button.enabled) {
        canvas.quads.fadeFrom(first, 0.4);
    }
}
