//! Application use case for reconciling runtime pane graphics.

const model_data = @import("../model.zig");
const core = @import("telar-core");
const ClientModel = @import("../state/ClientModel.zig");
pub const Command = @import("PaneGraphicsCommand.zig").PaneGraphicsCommand;

/// Commits whether one pane needs a cell fallback for host graphics.
/// Unknown panes and repeated values preserve the semantic revision.
///
/// ```zig
/// const commit = pane_graphics.setFallback(model, pane_id, true) orelse return;
/// ```
pub fn setFallback(model: *ClientModel, pane_id: core.PaneId, visible: bool) ?model_data.PaneGraphicsFallbackCommit {
    const pane = model.panes.find(pane_id) orelse return null;
    if (pane.graphics_placeholder == visible) {
        return null;
    }

    pane.graphics_placeholder = visible;

    model.pane_graphics_revision +%= 1;

    return .{
        .pane_id = pane_id,
        .visible = visible,
        .pane_graphics_revision = model.pane_graphics_revision,
    };
}
