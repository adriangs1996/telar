const std = @import("std");
const Canvas = @import("Canvas.zig");
const HitMap = @import("HitMap.zig");
const BandHitMap = @import("BandHitMap.zig");
const Button = @import("Button.zig");
const PixelButton = @import("PixelButton.zig");
const Action = @import("action.zig").Action;
const client = @import("telar-client");
const core = @import("telar-core");
const Context = @This();

canvas: *Canvas,
hits: *HitMap,
bands: *BandHitMap,
projection: *const client.Projection,
hovered: ?Action,

/// Paints a semantic control and its matching fixed hit target together.
/// Example: `try context.button(.{ .area = row, .intent = .toggle_sidebar, .text = "telar" });`
pub fn button(context: *Context, input: Button) !void {
    const palette = context.canvas.theme.palette;
    const action: Action = .{ .intent = input.intent };
    const hovered = context.isHovered(action);
    try context.canvas.fill(input.area, if (input.active) palette.accent else if (hovered) palette.surface1 else palette.surface0);
    try context.canvas.text(input.area, .{
        .text = input.text,
        .color = if (input.active) palette.surface_dim else if (hovered) palette.text else palette.subtext0,
        .bold = input.active,
    });
    try context.hits.add(.{ .area = input.area, .action = action });
}

/// Paints a rounded control inside a chrome band and registers its pixel
/// target. The active control fills with `accent`; hover lifts the surface;
/// an optional dot marks attention at the trailing edge.
/// Example: `try context.pill(.{ .area = bounds, .intent = .{ .select_workspace = id }, .text = "1 telar", .active = true });`
pub fn pill(context: *Context, input: PixelButton) !void {
    const palette = context.canvas.theme.palette;
    const action: Action = .{ .intent = input.intent };
    const hovered = context.isHovered(action);
    const fill: core.Color = if (input.active) palette.accent else if (hovered) palette.surface1 else palette.surface0;
    try context.canvas.fillRoundedPixels(input.area, .{ .radius = input.radius, .color = fill });
    const dot_space: f32 = if (input.dot != null) context.canvas.chrome.px(dot_diameter + dot_gap) else 0;
    var label_area = input.area;
    label_area.x += input.inset;
    label_area.width = @max(0, label_area.width - 2 * input.inset - dot_space);
    _ = try context.canvas.textPixels(label_area, .{
        .text = input.text,
        .color = if (input.active) palette.surface_dim else if (hovered) palette.text else palette.subtext0,
        .bold = input.bold or input.active,
        .face = input.face,
    });
    if (input.dot) |color| {
        try context.dot(input.area, color);
    }

    try context.bands.add(.{ .area = input.area, .action = action });
}

/// The attention dot of a pill or a tab, inside its trailing edge.
/// Example: `try context.dot(tab_bounds, palette.yellow);`
pub fn dot(context: *Context, bounds: @import("../render/Rect.zig"), color: core.Color) !void {
    const diameter = context.canvas.chrome.px(dot_diameter);
    const gap = context.canvas.chrome.px(dot_gap);
    const inset = @max(0, (bounds.height - diameter) / 2);
    try context.canvas.fillRoundedPixels(.{
        .x = @max(bounds.x, bounds.x + bounds.width - gap - diameter),
        .y = bounds.y + inset,
        .width = @min(diameter, bounds.width),
        .height = @min(diameter, bounds.height),
    }, .{ .radius = 999, .color = color });
}

/// Restricts a one-line label to the supplied row.
/// Example: `try context.label(row, "No agents");`
pub fn label(context: *Context, area: core.Rect, text: []const u8) !void {
    try context.canvas.text(area, .{ .text = text, .color = context.canvas.theme.palette.subtext0 });
}

fn isHovered(context: *const Context, action: Action) bool {
    return if (context.hovered) |value| std.meta.eql(value, action) else false;
}

/// Logical size and trailing gap of the attention dot.
pub const dot_diameter: f32 = 6;
pub const dot_gap: f32 = 6;
