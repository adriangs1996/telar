//! Wires committed sidebar state to disposable client resources.

const notifications_application = @import("telar-client").application.notifications;
const client_model = @import("telar-client").model;
const sidebar_projection = @import("sidebar_projection.zig");

const Client = @import("../../Client.zig");
const toggle_sidebar = notifications_application.toggle_sidebar;

/// Wires sidebar toggling to view, graphics and pane geometry resources.
///
/// ```zig
/// var use_case = handler(client);
/// _ = try use_case.execute();
/// ```
pub fn handler(client: *Client) toggle_sidebar.ToggleSidebarHandler {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .apply = applyVisibility,
        },
    };
}

/// Wires sidebar resizing to the same ordered projection as visibility.
///
/// ```zig
/// var use_case = resizeHandler(client);
/// _ = try use_case.execute(.{ .direction = .wider });
/// ```
pub fn resizeHandler(client: *Client) toggle_sidebar.ResizeSidebarHandler {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .apply = applyVisibility,
        },
    };
}

fn applyVisibility(context: *anyopaque, change: client_model.SidebarLayout) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try sidebar_projection.apply(client, change);
}
