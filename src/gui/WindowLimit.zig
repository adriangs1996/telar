//! The window's own limits that a frame can keep reaching. The window
//! reports one when it enters it and again only after leaving it, so a
//! limit held for many frames counts once.
pub const WindowLimit = enum {
    frame_widgets,
    band_hits,
    cell_hits,
    widget_targets,
    editors,
    frame_quads,
    cell_quads,
    image_placements,
    accessible_nodes,
    grid_cells,
    display_scale,
    glyph_page,
};
