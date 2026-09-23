//! Sidebar toggle: shows, hides and resizes the sidebar and reports its layout.
const data = @import("model");
const attached_client_tests = @import("../attached_client_tests.zig");
const pane_resize = @import("../panes/pane_resize.zig");
const Client = @import("../AttachedClient.zig");

/// Changes visibility and synchronizes pane geometry. Example: `_ = try toggle(client);`.
/// Example: `_ = try sidebar_toggle.toggleSidebar(app);`
pub fn toggleSidebar(client: *Client) !data.SidebarLayout {
    const change = client.model.toggleSidebar();
    try deliverSidebarLayout(client, change);
    return change;
}

/// Changes the exact or stepped width. Example: `_ = try resize(client, .{ .exact = 73 });`.
/// Example: `_ = try sidebar_toggle.resizeSidebar(app, requested);`
pub fn resizeSidebar(client: *Client, requested: data.SidebarResize) !?data.SidebarLayout {
    const change = switch (requested) {
        .exact => |width| client.model.setSidebarWidth(width),
        .direction => |direction| client.model.stepSidebarWidth(direction),
    } orelse return null;

    try deliverSidebarLayout(client, change);
    return change;
}

/// Applies one exact model commit to the view, physical graphics placements
/// and attached runtime pane geometry.
pub fn deliverSidebarLayout(client: *Client, change: data.SidebarLayout) !void {
    if (client.model.sidebar_visible != change.visible or client.model.sidebar_width != change.width or
        client.model.version().chrome != change.chrome_revision)
    {
        return error.StaleSidebarLayout;
    }

    client.model.to_host.invalidate_placements = true;
    const active = client.model.tabs.activeSlot() orelse return;
    try pane_resize.resizeAttachedPanes(client, active, client.geometry().area);
}

test "sidebar projection rejects changes that are not the current model commit" {
    try attached_client_tests.rejectStaleSidebarCommits(deliverSidebarLayout);
}
