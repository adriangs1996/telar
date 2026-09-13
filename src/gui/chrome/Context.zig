const std = @import("std");
const Canvas = @import("Canvas.zig");
const HitMap = @import("HitMap.zig");
const Button = @import("Button.zig");
const Action = @import("action.zig").Action;
const client = @import("telar-client");
const core = @import("telar-core");
const Context = @This();

canvas: *Canvas,
hits: *HitMap,
projection: *const client.Projection,
hovered: ?Action,

/// Paints a semantic control and its matching fixed hit target together.
/// Example: `try context.button(.{ .area = row, .intent = .toggle_sidebar, .text = "telar" });`
pub fn button(context: *Context, input: Button) !void {
    const palette = context.canvas.theme.palette;
    const action: Action = .{ .intent = input.intent };
    const hovered = if (context.hovered) |value| std.meta.eql(value, action) else false;
    try context.canvas.fill(input.area, if (input.active) palette.accent else if (hovered) palette.surface1 else palette.surface0);
    try context.canvas.text(input.area, .{
        .text = input.text,
        .color = if (input.active) palette.surface_dim else if (hovered) palette.text else palette.subtext0,
        .bold = input.active,
    });
    try context.hits.add(.{ .area = input.area, .action = action });
}

/// Restricts a one-line label to the supplied row.
/// Example: `try context.label(row, "No agents");`
pub fn label(context: *Context, area: core.Rect, text: []const u8) !void {
    try context.canvas.text(area, .{ .text = text, .color = context.canvas.theme.palette.subtext0 });
}
