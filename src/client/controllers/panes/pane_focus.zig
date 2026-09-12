//! Wires semantic pane focus to active-pane resource delivery.

const Client = @import("../../AttachedClient.zig");
const FocusPaneHandlerType = @import("../../application/panes/FocusPaneHandler.zig");
const PaneFocusType = @import("../../model/PaneFocus.zig");
const RectType = @import("telar-core").Rect;
const active_pane_resources = @import("active_pane_resources.zig");

/// Wires pane focus to the shared active-pane resource use case.
///
/// ```zig
/// var use_case = handler(client);
/// _ = try use_case.execute(.{ .target = .{ .direction = .left }, .area = area });
/// ```
pub fn handler(client: *Client) FocusPaneHandlerType {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .deliver = deliverFocus,
        },
    };
}

fn deliverFocus(context: *anyopaque, focus: PaneFocusType, area: RectType) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try active_pane_resources.deliverFocus(client, focus, area);
}
