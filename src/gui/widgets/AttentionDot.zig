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
pub fn draw(self: AttentionDot, canvas: *Canvas) !void {
    const dot_diameter = canvas.chrome.px(diameter);
    const dot_gap = canvas.chrome.px(gap);
    const inset = @max(0, (self.area.height - dot_diameter) / 2);
    try canvas.fillRoundedAt(.{
        .x = @max(self.area.x, self.area.x + self.area.width - dot_gap - dot_diameter),
        .y = self.area.y + inset,
        .width = @min(dot_diameter, self.area.width),
        .height = @min(dot_diameter, self.area.height),
    }, .{ .radius = 999, .color = self.color });
}
