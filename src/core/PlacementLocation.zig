/// Where a placement's image lands: at its anchor cell, or wherever Kitty
/// Unicode placeholder cells (`U=1`) name it, which the client finds in the
/// pane's cells and sizes against the placement's columns and rows.
pub const PlacementLocation = enum(u8) {
    cell = 0,
    placeholders = 1,
};
