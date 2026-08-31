//! Adapts model-owned pane focus reporting to runtime pane input.

const client_application = @import("application/root.zig");

const Client = @import("client.zig");
const pane_focus_reporting = client_application.pane_focus_reporting;
const runtime_transport = @import("runtime_transport.zig");

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

fn handler(client: *Client) pane_focus_reporting.PaneFocusReportingHandler {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .deliver = deliver,
        },
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
