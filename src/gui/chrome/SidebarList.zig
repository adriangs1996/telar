//! Where the sidebar's cards go: the cell column they may hit, the pixel
//! rectangle they are clipped to and the card geometry of this frame.
const core = @import("telar-core");
const Canvas = @import("Canvas.zig");
const Rect = @import("../render/Rect.zig");
const CardGeometry = @import("CardGeometry.zig");
const SidebarList = @This();

cells: core.Rect,
bounds: Rect,
geometry: CardGeometry,

/// The cells a card's pixel rectangle touches inside the list: the hit map
/// is cell-based, so the rows are rounded outwards and a boundary row shared
/// by two cards belongs to the later one, as later hits take precedence.
/// Example: `try hits.add(.{ .area = list.hitCells(canvas, card), .action = action });`
pub fn hitCells(list: SidebarList, canvas: *const Canvas, card: Rect) core.Rect {
    const cell_height: f32 = @floatFromInt(canvas.metrics.cell_height);
    const origin: f32 = @floatFromInt(canvas.origin[1]);
    const top = @max(card.y, list.bounds.y);
    const bottom = @min(card.y + card.height, list.bounds.y + list.bounds.height);
    if (bottom <= top) {
        return .{};
    }

    const first_row: u16 = @intFromFloat(@min(65535, @max(0, @floor((top - origin) / cell_height))));
    const end_row: u16 = @intFromFloat(@min(65535, @max(0, @ceil((bottom - origin) / cell_height))));
    const rows: core.Rect = .{ .x = list.cells.x, .y = first_row, .w = list.cells.w, .h = end_row -| first_row };
    return rows.intersect(list.cells);
}
