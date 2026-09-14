//! What one palette row shows: an icon column, a proportional label, muted
//! secondary text and a right-aligned monospace hint.
const core = @import("telar-core");
const Color = core.Color;
const Canvas = @import("../Canvas.zig");
const Label = @import("../Label.zig");
const PaletteRow = @This();

area: core.Rect = .{},
icon: []const u8,
primary: []const u8,
secondary: []const u8 = "",
hint: []const u8 = "",
/// Commands and paths keep the monospace face.
mono: bool = false,
/// Overrides the label color, for failures.
color: ?Color = null,

/// Reserves hint cells before clipping the primary and secondary labels.
/// Example: `try row.draw(canvas);`
pub fn draw(content: PaletteRow, canvas: *Canvas) !void {
    const row = content.area;
    if (row.isEmpty()) {
        return;
    }

    const colors = canvas.theme.palette;
    const parts = row.splitLeft(2);
    try canvas.text(parts[0], .{ .text = content.icon, .color = colors.subtext0 });
    const hint_cells = @min(core.measure(content.hint), parts[1].w);
    const body = parts[1].splitLeft(parts[1].w -| (hint_cells + 1))[0];
    const hint_area: core.Rect = .{ .x = row.x + row.w - hint_cells, .y = row.y, .w = hint_cells, .h = 1 };
    try canvas.text(hint_area, .{ .text = content.hint, .color = colors.subtext0 });
    const primary_label: Label = .{ .text = content.primary, .color = content.color orelse colors.text, .face = if (content.mono) .mono else .sans, .size = .body };
    try canvas.text(body, primary_label);
    if (content.secondary.len == 0 or body.w < 4) {
        return;
    }

    const cell: f32 = @floatFromInt(@max(canvas.metrics.cell_width, 1));
    const used: u16 = @intFromFloat(@ceil(try canvas.measure(primary_label) / cell));
    const rest = body.splitLeft(used + 1)[1];
    try canvas.text(rest, .{ .text = content.secondary, .color = colors.subtext0, .face = .sans, .size = .body });
}
