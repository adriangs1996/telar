const core = @import("telar-core");
const Canvas = @import("Canvas.zig");
const Rect = @import("../render/Rect.zig");
const AttentionDot = @This();

area: Rect,
color: core.Color,

pub const diameter: f32 = 6;
pub const gap: f32 = 6;

/// Paints an attention indicator inside a pill or tab's trailing edge.
/// Example: `try (AttentionDot{ .area = bounds, .color = palette.yellow }).draw(canvas);`
pub fn draw(dot: AttentionDot, canvas: *Canvas) !void {
    const dot_diameter = canvas.chrome.px(diameter);
    const dot_gap = canvas.chrome.px(gap);
    const inset = @max(0, (dot.area.height - dot_diameter) / 2);
    try canvas.fillRoundedAt(.{
        .x = @max(dot.area.x, dot.area.x + dot.area.width - dot_gap - dot_diameter),
        .y = dot.area.y + inset,
        .width = @min(dot_diameter, dot.area.width),
        .height = @min(dot_diameter, dot.area.height),
    }, .{ .radius = 999, .color = dot.color });
}
