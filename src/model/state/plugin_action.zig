//! A plugin action in the client model: the callback context it runs with and its execution.

const PluginExecution = @import("PluginExecution.zig");
const model_data = @import("../model.zig");
const core = @import("telar-core");
const ClientModel = @import("ClientModel.zig");

/// Builds the immutable value snapshot passed to one configured action.
///
/// ```zig
/// const context = plugin_action.callbackContext(model);
/// ```
pub fn callbackContext(model: *const ClientModel) model_data.CallbackContext {
    const slot = model.tabs.activeSlot() orelse return .{
        .sidebar_visible = model.sidebar_visible,
        .tab_count = 0,
        .active_tab_index = 0,
        .pane_count = 0,
        .focused_pane_id = 0,
    };
    const focused = model.tabs.layout[slot].focused();

    return .{
        .sidebar_visible = model.sidebar_visible,
        .tab_count = @intCast(model.tabs.count),
        .active_tab_index = @intCast(slot),
        .pane_count = @intCast(model.panes.countIn(model.tabs.location[slot].tab_id)),
        .focused_pane_id = if (focused) |pane_id| core.raw(pane_id) else 0,
    };
}

/// Reserves one plugin execution against the current configuration.
///
/// ```zig
/// const execution = try plugin_action.beginExecution(model) orelse return;
/// ```
pub fn beginExecution(model: *ClientModel) !?PluginExecution {
    return model.plugins.beginPluginExecution(model.configuration_generation);
}
