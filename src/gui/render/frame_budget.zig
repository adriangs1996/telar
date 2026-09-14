//! Geometry-time reservation for a terminal layer plus bounded overlapping UI.
const Mesh = @import("CellMesh.zig");
const core = @import("telar-core");

/// Includes the largest picker, the two visible toasts, link spans, the
/// pixel chrome (pills, tabs, location and status hints) and per-pane
/// decorations: header glyphs, chip, ring and dim.
/// Example: `try quads.reserve(frame_budget.quads(host_cells));`
pub fn quads(cells: usize) usize {
    const modal = @min(cells, 140 * 30);
    const notifications = @min(cells, 2 * 48 * 4);
    const link_preview = @min(cells, 100);
    const link_spans = cells;
    const chrome_bands = (core.max_workspace_list_entries + core.max_tabs_per_workspace) * (2 + 32) + 512;
    const pane_decorations = core.max_panes_per_tab * (Mesh.capacity + 64);
    return (cells + modal + notifications + link_preview) * Mesh.capacity + link_spans + pane_decorations + chrome_bands + 1024;
}
