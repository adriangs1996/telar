//! Commits sidebar preference and delivers its layout before returning.

const Client = @import("../../AttachedClient.zig");
const SidebarLayout = @import("../../model/SidebarLayout.zig");
const Resize = @import("../../application/notifications/toggle_sidebar.zig").Resize;
const sidebar_projection = @import("sidebar_projection.zig");

/// Changes visibility and synchronizes pane geometry. Example: `_ = try toggle(client);`.
pub fn toggle(client: *Client) !SidebarLayout {
    const change = client.model.toggleSidebar();
    try sidebar_projection.apply(client, change);
    return change;
}

/// Changes the exact or stepped width. Example: `_ = try resize(client, .{ .exact = 73 });`.
pub fn resize(client: *Client, requested: Resize) !?SidebarLayout {
    const change = switch (requested) {
        .exact => |width| client.model.setSidebarWidth(width),
        .direction => |direction| client.model.stepSidebarWidth(direction),
    } orelse return null;

    try sidebar_projection.apply(client, change);
    return change;
}
