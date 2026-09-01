//! Adapts runtime pane frames to recovery, resource delivery and telemetry.

const core = @import("telar-core");
const panes_application = @import("../../application/panes/root.zig");
const client_model = @import("../../model.zig");
const active_pane_resources = @import("active_pane_resources.zig");

const Client = @import("../../client.zig");
const diagnostics = core.diagnostics;
const pane_frame = panes_application.pane_frame;
const pane_frame_delivery = panes_application.pane_frame_delivery;
const runtime_transport = @import("../../runtime_transport.zig");
const schema = core.schema;

/// Reconciles one decoded runtime frame through the client application
/// boundary. Presentation observes the resulting model revision later.
///
/// ```zig
/// _ = try apply(client, frame);
/// ```
pub fn apply(client: *Client, frame: schema.frame.FrameView) !client_model.PaneFrameOutcome {
    const started = diagnostics.now(client.io);
    var use_case = handler(client);
    const outcome = try use_case.execute(frame);
    if (outcome == .applied) {
        const commit = outcome.applied;
        if (comptime diagnostics.enabled) {
            client.telemetry.metrics.frames += 1;
            client.telemetry.metrics.frame_cells += commit.cells;
            client.telemetry.metrics.frame_spans += commit.spans;
            client.telemetry.metrics.snapshots += @intFromBool(commit.snapshot);
            client.telemetry.metrics.apply.observe(diagnostics.elapsed(started, diagnostics.now(client.io)));
        }
    }

    return outcome;
}

fn handler(client: *Client) pane_frame.ApplyPaneFrameHandler {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .recover = requestSnapshot,
            .deliver = deliverResources,
        },
    };
}

fn requestSnapshot(context: *anyopaque, recovery: client_model.PaneFrameRecovery) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try runtime_transport.enqueue(client, .{ .request_snapshot = .{
        .pane_id = recovery.pane_id,
        .known_frame_id = recovery.known_frame_id,
    } });
}

fn deliverResources(context: *anyopaque, commit: client_model.PaneFrameCommit) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    var use_case: pane_frame_delivery.DeliverPaneFrameHandler = .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .pane_graphics_visible = paneGraphicsVisible,
            .set_pane_graphics_visible = setPaneGraphicsVisible,
            .synchronize_active_resources = synchronizeActiveResources,
        },
    };

    try use_case.execute(commit);
}

fn paneGraphicsVisible(context: *anyopaque, pane_id: schema.PaneId) bool {
    const client: *Client = @ptrCast(@alignCast(context));

    return client.graphics_store.paneVisible(pane_id);
}

fn setPaneGraphicsVisible(context: *anyopaque, pane_id: schema.PaneId, visible: bool) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try client.graphics_store.setPaneVisible(pane_id, visible);
}

fn synchronizeActiveResources(context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try active_pane_resources.synchronize(client);
}
