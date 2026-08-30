//! Synchronizes committed pane geometry with graphics and the runtime.

const std = @import("std");
const core = @import("telar-core");
const workspace_capability = @import("../workspace/root.zig");
const client_application = @import("application/root.zig");
const client_model = @import("model.zig");

const Client = @import("client.zig");
const resize_pane = client_application.resize_pane;
const schema = core.schema;
const tabs_mod = workspace_capability.tabs;
const toggle_pane_fullscreen = client_application.toggle_pane_fullscreen;

/// Wires pane edge resizing to the shared geometry effect.
///
/// ```zig
/// var use_case = resizeHandler(client);
/// _ = try use_case.execute(.{ .direction = .right, .area = area });
/// ```
pub fn resizeHandler(client: *Client) resize_pane.ResizePaneHandler {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .apply = applyGeometry,
        },
    };
}

/// Wires fullscreen toggling to the shared geometry effect.
///
/// ```zig
/// var use_case = fullscreenHandler(client);
/// _ = try use_case.execute(.{ .area = area });
/// ```
pub fn fullscreenHandler(client: *Client) toggle_pane_fullscreen.TogglePaneFullscreenHandler {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .apply = applyGeometry,
        },
    };
}

fn applyGeometry(context: *anyopaque, change: client_model.PaneGeometryChange) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const tab = findTab(&client.model.workspace, change.location) orelse return error.UnexpectedPaneGeometry;
    const active = client.model.workspace.active() orelse return error.UnexpectedPaneGeometry;
    if (active != tab or active.model.layout.focused() != change.focused or
        active.model.layout.isFullscreen() != change.fullscreen or
        client.model.version().panes != change.panes_revision)
    {
        return error.UnexpectedPaneGeometry;
    }

    client.graphics_store.invalidatePlacements();
    try client.resizeAttached(&active.model, change.area);
}

fn findTab(workspace: *tabs_mod.Model, location: schema.TabLocation) ?*tabs_mod.Tab {
    const tab = workspace.find(location.tab_id) orelse return null;
    if (!std.meta.eql(tab.location, location)) {
        return null;
    }

    return tab;
}
