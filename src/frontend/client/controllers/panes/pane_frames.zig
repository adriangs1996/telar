//! Adapts runtime pane frames to recovery, resource delivery and telemetry.

const Client = @import("../../Client.zig");
const FrameViewType = @import("telar-core").FrameView;
const PaneFrameOutcomeType = @import("telar-client").PaneFrameOutcome;
const now_module = @import("telar-core").now;
const enabled_module = @import("telar-core").enabled;
const elapsed_module = @import("telar-core").elapsed;
const attachment_prompts = @import("../input/attachment_prompts.zig");
const kitty_delivery = @import("../../../graphics/kitty_delivery.zig");
const pane_geometry = @import("pane_geometry.zig");
const ApplyPaneFrameHandlerType = @import("telar-client").ApplyPaneFrameHandler;
const PaneFrameRecoveryType = @import("telar-client").PaneFrameRecovery;
const runtime_transport = @import("../../entrypoints/runtime_io.zig");
const PaneFrameCommitType = @import("telar-client").PaneFrameCommit;
const DeliverPaneFrameHandlerType = @import("telar-client").DeliverPaneFrameHandler;
const PaneIdType = @import("telar-core").PaneId;
const active_pane_resources = @import("active_pane_resources.zig");

/// Reconciles one decoded runtime frame through the client application
/// boundary. Presentation observes the resulting model revision later.
///
/// ```zig
/// _ = try apply(client, frame);
/// ```
pub fn apply(client: *Client, frame: FrameViewType) !PaneFrameOutcomeType {
    const started = now_module(client.io);
    var use_case = handler(client);
    const outcome = try use_case.execute(frame);
    if (outcome == .applied) {
        const commit = outcome.applied;
        if (comptime enabled_module) {
            client.telemetry.metrics.frames += 1;
            client.telemetry.metrics.frame_cells += commit.cells;
            client.telemetry.metrics.frame_spans += commit.spans;
            client.telemetry.metrics.snapshots += @intFromBool(commit.snapshot);
            client.telemetry.metrics.apply.observe(elapsed_module(started, now_module(client.io)));
        }
        if (attachment_prompts.reconcileFrame(client, commit.pane_id)) {
            kitty_delivery.invalidatePlacements(&client.graphics_store);
            try pane_geometry.offerActive(client, client.geometry().area);
        }
    }

    return outcome;
}

fn handler(client: *Client) ApplyPaneFrameHandlerType {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .recover = requestSnapshot,
            .deliver = deliverResources,
        },
    };
}

fn requestSnapshot(context: *anyopaque, recovery: PaneFrameRecoveryType) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try runtime_transport.enqueue(client, .{ .request_snapshot = .{
        .pane_id = recovery.pane_id,
        .known_frame_id = recovery.known_frame_id,
    } });
}

fn deliverResources(context: *anyopaque, commit: PaneFrameCommitType) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    var use_case: DeliverPaneFrameHandlerType = .{
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

fn paneGraphicsVisible(context: *anyopaque, pane_id: PaneIdType) bool {
    const client: *Client = @ptrCast(@alignCast(context));

    return client.graphics_store.paneVisible(pane_id);
}

fn setPaneGraphicsVisible(context: *anyopaque, pane_id: PaneIdType, visible: bool) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try client.graphics_store.setPaneVisible(pane_id, visible);
}

fn synchronizeActiveResources(context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try active_pane_resources.synchronize(client);
}
