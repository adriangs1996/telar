//! Resizing a pane inside its tab's layout.

const model_data = @import("../model.zig");
const ClientModel = @import("../state/ClientModel.zig");

/// Moves the nearest split edge around the focused pane and reports the
/// committed pane revision. Missing axes and constrained edges are no-ops.
///
/// ```zig
/// const resize = pane_resize.resizePane(model, .{ .direction = .right, .area = area }) orelse return;
/// ```
pub fn resizePane(model: *ClientModel, request: model_data.ResizePaneRequest) ?model_data.PaneGeometryChange {
    const slot = model.tabs.activeSlot() orelse return null;
    const layout = &model.tabs.layout[slot];
    const focused = layout.focused() orelse return null;
    if (!layout.resizeFocused(request.direction, request.area)) {
        return null;
    }

    model.panes_revision +%= 1;

    return .{
        .location = model.tabs.location[slot],
        .focused = focused,
        .panes_revision = model.panes_revision,
        .area = request.area,
        .fullscreen = layout.isFullscreen(),
    };
}
