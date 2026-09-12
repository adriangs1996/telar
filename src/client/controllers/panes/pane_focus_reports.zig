//! Adapts model-owned pane focus reporting and canonical retirement.

const Client = @import("../../AttachedClient.zig");
const ApplicationPanesPaneFocusReportingOutcome = @import("../../application/panes/pane_focus_reporting.zig").Outcome;
const RetireReportedPaneFocusHandlerType = @import("../../application/panes/RetireReportedPaneFocusHandler.zig");
const PaneFocusReportingHandlerType = @import("../../application/panes/PaneFocusReportingHandler.zig");
const PaneFocusReportingEffects = @import("../../application/panes/PaneFocusReportingEffects.zig");
const DeliveryType = @import("../../application/panes/PaneFocusDelivery.zig");
const runtime_transport = @import("../../entrypoints/runtime_io.zig");

/// Synchronizes the active focused pane with child focus reporting.
///
/// ```zig
/// _ = try sync(client);
/// ```
pub fn sync(client: *Client) !ApplicationPanesPaneFocusReportingOutcome {
    var use_case = handler(client);

    return use_case.execute(.sync);
}

/// Clears intentional focus ownership before detaching its pane.
///
/// ```zig
/// _ = try clear(client);
/// ```
pub fn clear(client: *Client) !ApplicationPanesPaneFocusReportingOutcome {
    var use_case = handler(client);

    return use_case.execute(.clear);
}

/// Retires stale reported focus after a canonical transition. No child input
/// can be emitted by this use case.
///
/// ```zig
/// _ = retire(client);
/// ```
pub fn retire(client: *Client) ApplicationPanesPaneFocusReportingOutcome {
    var use_case: RetireReportedPaneFocusHandlerType = .{
        .model = &client.model,
    };

    return use_case.execute();
}

fn handler(client: *Client) PaneFocusReportingHandlerType {
    return .{
        .model = &client.model,
        .effects = effects(client),
    };
}

/// Returns the focus-report delivery port reused by compound application flows.
///
/// ```zig
/// const focus_effects = effects(client);
/// ```
pub fn effects(client: *Client) PaneFocusReportingEffects {
    return .{
        .context = client,
        .deliver = deliver,
    };
}

fn deliver(raw_context: *anyopaque, delivery: DeliveryType) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));
    const bytes = switch (delivery.direction) {
        .focus_out => "\x1b[O",
        .focus_in => "\x1b[I",
    };

    try runtime_transport.enqueueInput(client, delivery.pane_id, bytes);
}
