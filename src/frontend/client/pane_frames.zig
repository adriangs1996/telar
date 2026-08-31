//! Adapts committed pane frames to recovery, graphics, focus and telemetry.

const std = @import("std");
const core = @import("telar-core");
const client_application = @import("application/root.zig");
const client_model = @import("model.zig");
const pane_focus = @import("pane_focus.zig");

const Client = @import("client.zig");
const diagnostics = core.diagnostics;
const pane_frame = client_application.pane_frame;
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
            .apply = applyResources,
        },
    };
}

fn requestSnapshot(context: *anyopaque, recovery: client_model.PaneFrameRecovery) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try client.enqueue(.{ .request_snapshot = .{
        .pane_id = recovery.pane_id,
        .known_frame_id = recovery.known_frame_id,
    } });
}

fn applyResources(context: *anyopaque, commit: client_model.PaneFrameCommit) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const tab = client.model.workspace.find(commit.location.tab_id) orelse
        return error.UnexpectedPaneFrame;
    if (!std.meta.eql(tab.location, commit.location)) {
        return error.UnexpectedPaneFrame;
    }

    const pane = tab.model.find(commit.pane_id) orelse return error.UnexpectedPaneFrame;
    const active = client.model.workspace.active();
    const graphics_visible = pane.scroll.atBottom(pane.buffer.h) and
        active != null and std.meta.eql(active.?.location, tab.location);
    if (!pane.attached or pane.applied_frame_id != commit.frame_id or
        client.model.version().frame != commit.frame_revision or
        graphics_visible != commit.graphics_visible)
    {
        return error.UnexpectedPaneFrame;
    }

    if (client.graphics_store.paneVisible(commit.pane_id) != commit.graphics_visible) {
        try client.graphics_store.setPaneVisible(commit.pane_id, commit.graphics_visible);
    }
    if (active != null) {
        try pane_focus.syncResources(client);
    }
}
