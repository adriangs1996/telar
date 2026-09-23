const action_module = @import("action.zig");
const core = @import("telar-core");
const client = @import("telar-client");
const Canvas = @import("Canvas.zig");
const Context = @import("Context.zig");
const Button = @This();

context: *const Context,
area: core.Rect,
intent: client.Intent,
text: []const u8,
active: bool = false,

/// Paints a semantic control and registers its matching grid hit target.
/// Example: `try button.draw(canvas);`
pub fn draw(self: Button, canvas: *Canvas) !void {
    const palette = canvas.theme.palette;
    const action: action_module.Action = .{ .intent = self.intent };
    const hovered = self.context.isHovered(action);
    try canvas.fill(self.area, if (self.active) palette.accent else if (hovered) palette.surface1 else palette.surface0);
    try canvas.text(self.area, .{
        .text = self.text,
        .color = if (self.active) palette.surface_dim else if (hovered) palette.text else palette.subtext0,
        .bold = self.active,
    });
    try self.context.hits.add(.{ .area = self.area, .action = action });
}
