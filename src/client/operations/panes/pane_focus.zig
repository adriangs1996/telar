const Client = @import("../../AttachedClient.zig");
const PaneFocusRequest = @import("../../model/PaneFocusRequest.zig");
const PaneLayoutRequest = @import("../../model/PaneLayoutRequest.zig");
const PaneFocus = @import("../../model/PaneFocus.zig");

/// Commits focus before synchronizing attachments and child focus. Example: `_ = try apply(client, command);`
pub fn apply(client: *Client, command: PaneFocusRequest) !?PaneFocus {
    const focus = client.model.focusPane(command) orelse return null;
    try client.deliverPaneFocus(focus, command.area);

    return focus;
}

/// Commits a membership-checked layout before delivering its geometry. Example: `try applyLayout(client, request);`
pub fn applyLayout(client: *Client, request: PaneLayoutRequest) !void {
    const focus = try client.model.applyPaneLayout(request);
    try client.deliverPaneFocus(focus, request.area);
}
