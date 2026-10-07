//! Limit reached, the model's side: a pane
//! whose graphics paused at a limit keeps its pause row only while the
//! client mirrors it, so no row outlives its pane and the table never fills
//! with panes that are gone.
const ClientModel = @import("../state/ClientModel.zig");

/// Removes the pause rows of panes that left the model. Every flow that
/// removes panes calls it once after removing them; it walks the pause
/// rows only, so it costs one comparison while no pane is paused.
///
/// ```zig
/// model.panes.removeTab(tab_id);
/// limit_reached.forgetClosedPanes(model);
/// ```
pub fn forgetClosedPanes(model: *ClientModel) void {
    const pauses = &model.graphics_pauses;
    var slot = pauses.count;
    while (slot > 0) {
        slot -= 1;
        if (model.panes.findConst(pauses.pane_id[slot]) == null) {
            pauses.remove(slot);
        }
    }
}
