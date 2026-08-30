//! Wires semantic pane focus to one client's focus and geometry resources.

const std = @import("std");
const core = @import("telar-core");
const workspace_capability = @import("../workspace/root.zig");
const client_application = @import("application/root.zig");
const client_model = @import("model.zig");

const Client = @import("client.zig");
const focus_pane = client_application.focus_pane;
const schema = core.schema;
const tabs_mod = workspace_capability.tabs;
const ui = core.ui;

pub const Target = focus_pane.Target;

/// Wires pane focus to terminal focus reports and fullscreen geometry.
///
/// ```zig
/// var use_case = handler(client);
/// _ = try use_case.execute(.{ .target = .{ .direction = .left }, .area = area });
/// ```
pub fn handler(client: *Client) focus_pane.FocusPaneHandler {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .apply = applyFocus,
        },
    };
}

fn applyFocus(context: *anyopaque, focus: client_model.PaneFocus, area: ui.Rect) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const tab = findTab(&client.model.workspace, focus.location) orelse return error.UnexpectedPaneFocus;
    const active = client.model.workspace.active() orelse return error.UnexpectedPaneFocus;
    if (active != tab or active.model.layout.focused() != focus.focused) {
        return error.UnexpectedPaneFocus;
    }

    try client.syncPaneFocus(&active.model);
    if (!focus.geometry_changed) {
        return;
    }

    client.graphics_store.invalidatePlacements();
    try client.resizeAttached(&active.model, area);
}

fn findTab(workspace: *tabs_mod.Model, location: schema.TabLocation) ?*tabs_mod.Tab {
    const tab = workspace.find(location.tab_id) orelse return null;
    if (!std.meta.eql(tab.location, location)) {
        return null;
    }

    return tab;
}
