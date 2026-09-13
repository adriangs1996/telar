//! Geometry-time reservation for a terminal layer plus bounded overlapping UI.
const Mesh = @import("CellMesh.zig");
const core = @import("telar-core");

/// Includes the largest picker, four toasts, link spans and control decorations.
/// Example: `try quads.reserve(frame_budget.quads(host_cells));`
pub fn quads(cells: usize) usize {
    const modal = @min(cells, 140 * 30);
    const notifications = @min(cells, 4 * 48 * 4);
    const link_preview = @min(cells, 100);
    const link_spans = cells;
    return (cells + modal + notifications + link_preview) * Mesh.capacity + link_spans + core.max_panes_per_tab * (Mesh.capacity + 8) + 1024;
}
