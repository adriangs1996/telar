//! Showing one pane over its whole tab and back.

const model_data = @import("../model.zig");
const ClientModel = @import("../state/ClientModel.zig");

/// Toggles fullscreen for the focused pane without discarding tiled
/// geometry. Absent or empty layouts leave every version intact.
///
/// ```zig
/// const change = pane_fullscreen.toggle(model, .{ .area = area }) orelse return;
/// ```
pub fn toggle(model: *ClientModel, request: model_data.TogglePaneFullscreenRequest) ?model_data.PaneGeometryChange {
    const slot = model.tabs.activeSlot() orelse return null;
    const layout = &model.tabs.layout[slot];
    const focused = layout.focused() orelse return null;
    if (!layout.toggleFullscreen()) {
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
