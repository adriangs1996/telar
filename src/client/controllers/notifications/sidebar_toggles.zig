//! Wires committed sidebar state to disposable client resources.

const Client = @import("../../AttachedClient.zig");
const ToggleSidebarHandlerType = @import("../../application/notifications/ToggleSidebarHandler.zig");
const ResizeSidebarHandlerType = @import("../../application/notifications/ResizeSidebarHandler.zig");
const SidebarLayoutType = @import("../../model/SidebarLayout.zig");
const sidebar_projection = @import("sidebar_projection.zig");

/// Wires sidebar toggling to view, graphics and pane geometry resources.
///
/// ```zig
/// var use_case = handler(client);
/// _ = try use_case.execute();
/// ```
pub fn handler(client: *Client) ToggleSidebarHandlerType {
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
pub fn resizeHandler(client: *Client) ResizeSidebarHandlerType {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .apply = applyVisibility,
        },
    };
}

fn applyVisibility(context: *anyopaque, change: SidebarLayoutType) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try sidebar_projection.apply(client, change);
}
