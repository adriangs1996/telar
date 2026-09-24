//! The focused pane's title and foreground process as the chrome shows them.

const std = @import("std");
const tab_layout = @import("../workspace/tab_layout.zig");
const ClientModel = @import("../state/ClientModel.zig");

/// Returns the window title the focused pane of the active tab last set,
/// or an empty slice.
///
/// ```zig
/// const title = pane_title.focusedTitle(model);
/// ```
pub fn focusedTitle(model: *const ClientModel) []const u8 {
    const slot = model.tabs.activeSlot() orelse return "";
    const pane = tab_layout.focusedPaneConst(model, slot) orelse return "";
    return pane.titleSlice();
}

/// Returns the executable name observed for the focused pane, or an empty slice.
///
/// ```zig
/// if (std.mem.eql(u8, pane_title.focusedForeground(model), "nvim")) {
///     routeToEditor();
/// }
/// ```
pub fn focusedForeground(model: *const ClientModel) []const u8 {
    const slot = model.tabs.activeSlot() orelse return "";
    const pane = tab_layout.focusedPaneConst(model, slot) orelse return "";
    return pane.foregroundName();
}
