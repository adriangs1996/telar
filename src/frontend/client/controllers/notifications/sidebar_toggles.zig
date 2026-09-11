//! Wires committed sidebar state to disposable client resources.

const Client = @import("../../Client.zig");
const ToggleSidebarHandlerType = @import("telar-client").ToggleSidebarHandler;
const ResizeSidebarHandlerType = @import("telar-client").ResizeSidebarHandler;
const SidebarLayoutType = @import("telar-client").SidebarLayout;
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
