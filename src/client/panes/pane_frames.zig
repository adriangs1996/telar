//! Pane frames: applies a pane frame and the progress it reports.
const sidebar_animation = @import("../notifications/sidebar_animation.zig");
const data = @import("model");
const core = @import("telar-core");
const agent_attachments = @import("../attachments/agent_attachments.zig");
const pane_focus = @import("pane_focus.zig");
const pane_resize = @import("pane_resize.zig");
const Client = @import("../AttachedClient.zig");

/// Applies validated cells and acknowledges ownership before host resources.
pub fn receivePaneFrame(client: *Client, frame: core.FrameView) !data.PaneFrameOutcome {
    core.profiling.add(.client_apply_frame, 1);
    const profile_started = core.profiling.start(client.io);
    defer core.profiling.finish(client.io, .client_frame, profile_started);
    const started = core.now(client.io);
    const outcome = try data.pane_frame.receive(&client.model, frame);
    switch (outcome) {
        .detached => {},
        .resync => {},
        .applied => |commit| {
            if (client.graphics.paneVisible(commit.pane_id) != commit.graphics_visible) {
                try client.graphics.setPaneVisible(commit.pane_id, commit.graphics_visible);
            }

            if (client.model.tabs.activeSlot() != null) {
                try pane_focus.synchronizeActivePane(client);
            }
        },
    }

    if (outcome == .applied) {
        const commit = outcome.applied;
        if (comptime core.enabled) {
            client.telemetry.metrics.frames += 1;
            client.telemetry.metrics.frame_cells += commit.cells;
            client.telemetry.metrics.frame_spans += commit.spans;
            client.telemetry.metrics.snapshots += @intFromBool(commit.snapshot);
            client.telemetry.metrics.apply.observe(core.elapsed(started, core.now(client.io)));
        }

        if (agent_attachments.reconcileAttachmentFrame(client, commit.pane_id)) {
            client.model.to_host.invalidate_placements = true;
            if (client.model.tabs.activeSlot()) |tab| {
                try pane_resize.resizeAttachedPanes(client, tab, client.geometry().area);
            }
        }
    }

    return outcome;
}

/// Stores one decoded terminal progress report and maintains animation liveness.
pub fn applyPaneProgress(client: *Client, message: core.PaneProgress) !?data.PaneProgressCommit {
    const commit = client.model.updatePaneProgress(message) orelse return null;
    _ = try sidebar_animation.synchronizeSidebarAnimation(client);
    return commit;
}
