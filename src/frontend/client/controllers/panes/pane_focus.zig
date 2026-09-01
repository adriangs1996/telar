//! Wires semantic pane focus to active-pane resource delivery.

const core = @import("telar-core");
const panes_application = @import("../../application/panes/root.zig");
const client_model = @import("../../model.zig");
const active_pane_resources = @import("active_pane_resources.zig");

const Client = @import("../../client.zig");
const focus_pane = panes_application.focus_pane;
const ui = core.ui;

pub const Target = focus_pane.Target;

/// Wires pane focus to the shared active-pane resource use case.
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
            .deliver = deliverFocus,
        },
    };
}

fn deliverFocus(context: *anyopaque, focus: client_model.PaneFocus, area: ui.Rect) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try active_pane_resources.deliverFocus(client, focus, area);
}
