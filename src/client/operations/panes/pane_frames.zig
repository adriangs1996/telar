//! Adapts runtime pane frames to recovery, resource delivery and telemetry.

const Client = @import("../../AttachedClient.zig");
const FrameViewType = @import("telar-core").FrameView;
const FrameAckType = @import("telar-core").FrameAck;
const PaneFrameOutcomeType = @import("../../model/types.zig").PaneFrameOutcome;
const now_module = @import("telar-core").now;
const enabled_module = @import("telar-core").enabled;
const elapsed_module = @import("telar-core").elapsed;
const attachment_prompts = @import("../input/attachment_prompts.zig");
const pane_geometry = @import("pane_geometry.zig");
const PaneFrameRecoveryType = @import("../../model/PaneFrameRecovery.zig");
const runtime_transport = @import("../../entrypoints/runtime_io.zig");
const active_pane_resources = @import("active_pane_resources.zig");

/// Applies validated cells and acknowledges ownership before host resources. Example: `_ = try apply(client, frame);`
pub fn apply(client: *Client, frame: FrameViewType) !PaneFrameOutcomeType {
    const started = now_module(client.io);
    const outcome = try client.model.applyPaneFrame(frame);
    switch (outcome) {
        .detached => {},
        .resync => |recovery| try requestSnapshot(client, recovery),
        .applied => |commit| {
            try acknowledgeFrame(client, .{ .pane_id = commit.pane_id, .frame_id = commit.frame_id });
            if (client.graphics.paneVisible(commit.pane_id) != commit.graphics_visible) {
                try client.graphics.setPaneVisible(commit.pane_id, commit.graphics_visible);
            }

            if (client.model.workspace.activeConst() != null) {
                try active_pane_resources.synchronize(client);
            }
        },
    }
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
            client.host_graphics.invalidatePlacements();
            try pane_geometry.offerActive(client, client.geometry().area);
        }
    }

    return outcome;
}

fn acknowledgeFrame(client: *Client, ack: FrameAckType) !void {
    const started = now_module(client.io);
    try runtime_transport.enqueue(client, .{ .frame_ack = ack });

    if (comptime enabled_module) {
        client.telemetry.metrics.ack_enqueue.observe(elapsed_module(started, now_module(client.io)));
    }
}

fn requestSnapshot(client: *Client, recovery: PaneFrameRecoveryType) !void {
    try runtime_transport.enqueue(client, .{ .request_snapshot = .{
        .pane_id = recovery.pane_id,
        .known_frame_id = recovery.known_frame_id,
    } });
}
