//! What one pass over a pane's graphics found and dropped, for the caller to
//! report.
const GraphicsTrim = @This();

images_found: usize = 0,
images_dropped: usize = 0,
placements_found: usize = 0,
placements_dropped: usize = 0,

/// Folds another screen's pass into this one: the most either screen held,
/// and everything both dropped.
///
/// ```zig
/// var trim = enforceGraphicsCounts(io, pane, .primary);
/// trim.add(enforceGraphicsCounts(io, pane, .alternate));
/// ```
pub fn add(self: *GraphicsTrim, other: GraphicsTrim) void {
    self.images_found = @max(self.images_found, other.images_found);
    self.images_dropped += other.images_dropped;
    self.placements_found = @max(self.placements_found, other.placements_found);
    self.placements_dropped += other.placements_dropped;
}
