//! Wires semantic pane layout resizing to graphics and runtime geometry.

const std = @import("std");
const core = @import("telar-core");
const workspace_capability = @import("../workspace/root.zig");
const client_application = @import("application/root.zig");
const client_model = @import("model.zig");

const Client = @import("client.zig");
const resize_pane = client_application.resize_pane;
const schema = core.schema;
const tabs_mod = workspace_capability.tabs;

/// Wires pane layout resizing to host graphics and runtime pane sizes.
///
/// ```zig
/// var use_case = handler(client);
/// _ = try use_case.execute(.{ .direction = .right, .area = area });
/// ```
pub fn handler(client: *Client) resize_pane.ResizePaneHandler {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .apply = applyResize,
        },
    };
}

fn applyResize(context: *anyopaque, resize: client_model.PaneLayoutResize) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const tab = findTab(&client.model.workspace, resize.location) orelse return error.UnexpectedPaneResize;
    const active = client.model.workspace.active() orelse return error.UnexpectedPaneResize;
    if (active != tab or active.model.layout.focused() != resize.focused or
        client.model.version().panes != resize.panes_revision)
    {
        return error.UnexpectedPaneResize;
    }

    client.graphics_store.invalidatePlacements();
    try client.resizeAttached(&active.model, resize.area);
}

fn findTab(workspace: *tabs_mod.Model, location: schema.TabLocation) ?*tabs_mod.Tab {
    const tab = workspace.find(location.tab_id) orelse return null;
    if (!std.meta.eql(tab.location, location)) {
        return null;
    }

    return tab;
}
