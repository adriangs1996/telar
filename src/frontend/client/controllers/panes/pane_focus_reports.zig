//! Adapts model-owned pane focus reporting and canonical retirement.

const panes_application = @import("../../application/panes/root.zig");

const Client = @import("../../client.zig");
const pane_focus_reporting = panes_application.pane_focus_reporting;
const runtime_transport = @import("../../connection/runtime_transport.zig");

pub const Outcome = pane_focus_reporting.Outcome;

/// Synchronizes the active focused pane with child focus reporting.
///
/// ```zig
/// _ = try sync(client);
/// ```
pub fn sync(client: *Client) !Outcome {
    var use_case = handler(client);

    return use_case.execute(.sync);
}

/// Clears intentional focus ownership before detaching its pane.
///
/// ```zig
/// _ = try clear(client);
/// ```
pub fn clear(client: *Client) !Outcome {
    var use_case = handler(client);

    return use_case.execute(.clear);
}

/// Retires stale reported focus after a canonical transition. No child input
/// can be emitted by this use case.
///
/// ```zig
/// _ = retire(client);
/// ```
pub fn retire(client: *Client) Outcome {
    var use_case: pane_focus_reporting.RetireReportedPaneFocusHandler = .{
        .model = &client.model,
    };

    return use_case.execute();
}

fn handler(client: *Client) pane_focus_reporting.PaneFocusReportingHandler {
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
pub fn effects(client: *Client) pane_focus_reporting.Effects {
    return .{
        .context = client,
        .deliver = deliver,
    };
}

fn deliver(raw_context: *anyopaque, delivery: pane_focus_reporting.Delivery) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));
    const bytes = switch (delivery.direction) {
        .focus_out => "\x1b[O",
        .focus_in => "\x1b[I",
    };

    try runtime_transport.enqueueInput(client, delivery.pane_id, bytes);
}
