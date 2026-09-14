const core = @import("telar-core");
const client = @import("telar-client");
const Canvas = @import("Canvas.zig");
const Context = @import("Context.zig");
const Action = @import("action.zig").Action;
const Button = @This();

context: *const Context,
area: core.Rect,
intent: client.Intent,
text: []const u8,
active: bool = false,

/// Paints a semantic control and registers its matching grid hit target.
/// Example: `try button.draw(canvas);`
pub fn draw(button: Button, canvas: *Canvas) !void {
    const palette = canvas.theme.palette;
    const action: Action = .{ .intent = button.intent };
    const hovered = button.context.isHovered(action);
    try canvas.fill(button.area, if (button.active) palette.accent else if (hovered) palette.surface1 else palette.surface0);
    try canvas.text(button.area, .{
        .text = button.text,
        .color = if (button.active) palette.surface_dim else if (hovered) palette.text else palette.subtext0,
        .bold = button.active,
    });
    try button.context.hits.add(.{ .area = button.area, .action = action });
}
