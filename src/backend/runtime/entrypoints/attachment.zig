//! Entrypoints for one client's disposable pane attachments.

const std = @import("std");
const vt = @import("ghostty-vt");
const core = @import("telar-core");
const agent_mod = @import("../../agent/root.zig");
const pane_mod = @import("../../pane/root.zig");
const attachment_mod = @import("../attachment.zig");
const delivery_mod = @import("../delivery.zig");
const telemetry_mod = @import("../telemetry.zig");
const common = @import("common.zig");

const Io = std.Io;
const AttachmentStore = attachment_mod.AttachmentStore;
const Delivery = delivery_mod.Delivery;
const RuntimeMetrics = telemetry_mod.RuntimeMetrics;
const schema = core.schema;
const diagnostics = core.diagnostics;

pub fn paneInput(io: Io, attachments: *AttachmentStore, metrics: *RuntimeMetrics, agents: *agent_mod.Registry, observe_agent_input: bool, scheduler: common.Scheduler, input: schema.PaneInput) !void {
    const active = attachments.find(input.pane_id) orelse {
        metrics.stale_client_messages += 1;
        return;
    };
    if (active.pane.exit != null) {
        metrics.stale_client_messages += 1;
        return;
    }
    if (comptime diagnostics.enabled) {
        metrics.input_events += 1;
        metrics.input_bytes += input.bytes.len;
    }
    if (observe_agent_input) _ = agents.observeInput(active.pane.key(), input.bytes);
    active.pane.queueHistoryInput(
        input.bytes,
        active.pane.session.shellForeground() orelse false,
        pane_mod.historyClock(io),
    );
    try scheduler.observation(scheduler.context, active.pane);
    _ = active.pane.input_queue.push(input.bytes);
    try scheduler.input(scheduler.context, active.pane);
}

pub fn paneResize(
    attachments: *AttachmentStore,
    metrics: *RuntimeMetrics,
    client: common.ClientKey,
    geometry: common.Geometry,
    scheduler: common.Scheduler,
    resize: schema.PaneResize,
) !void {
    const active = attachments.find(resize.pane_id) orelse {
        metrics.stale_client_messages += 1;
        return;
    };
    if (!geometry.holds(geometry.context, client, active.pane.location.workspace)) {
        metrics.geometry_rejections += 1;
        return;
    }
    try active.pane.requestResize(resize.size);
    if (!active.pane.ingest_pending) {
        active.pane.applyPendingResize() catch {
            active.pane.close_requested = true;
            active.pane.session.shutdown();
            return;
        };
        try scheduler.observation(scheduler.context, active.pane);
        try scheduler.media(scheduler.context, active.pane);
        _ = active.resizeIfNeeded() catch {
            _ = attachments.detach(resize.pane_id);
            return;
        };
    }
    if (!active.pane.ingest_pending)
        try scheduler.response(scheduler.context, active.pane);
}

pub fn setPaneViewport(
    attachments: *AttachmentStore,
    metrics: *RuntimeMetrics,
    viewport: schema.SetPaneViewport,
) !void {
    const active = attachments.find(viewport.pane_id) orelse {
        metrics.stale_client_messages += 1;
        return;
    };
    try active.setViewport(viewport.offset);
}

pub fn copySelection(
    attachments: *AttachmentStore,
    delivery: *Delivery,
    metrics: *RuntimeMetrics,
    request: schema.CopySelection,
) void {
    const active = attachments.find(request.pane_id) orelse {
        metrics.stale_client_messages += 1;
        return;
    };
    const screen = active.pane.terminal.screens.active;
    const cols = active.pane.screen.w;
    const start_y = if (request.linewise)
        @min(request.start_y, request.end_y)
    else
        request.start_y;
    const end_y = if (request.linewise)
        @max(request.start_y, request.end_y)
    else
        request.end_y;
    const start_x: u16 = if (request.linewise) 0 else @min(request.start_x, cols - 1);
    const end_x: u16 = if (request.linewise) cols - 1 else @min(request.end_x, cols - 1);
    const start = screen.pages.pin(.{ .screen = .{
        .x = start_x,
        .y = start_y,
    } }) orelse screen.pages.getBottomRight(.screen) orelse return;
    const end = screen.pages.pin(.{ .screen = .{
        .x = end_x,
        .y = end_y,
    } }) orelse screen.pages.getBottomRight(.screen) orelse return;
    var allocator = std.heap.FixedBufferAllocator.init(&delivery.clipboard_storage);
    const selected = screen.selectionString(allocator.allocator(), .{
        .sel = vt.Selection.init(start, end, false),
    }) catch return;
    _ = delivery.setClipboard(request.pane_id, selected);
}

pub fn requestGraphicsSnapshot(
    attachments: *AttachmentStore,
    metrics: *RuntimeMetrics,
    request: schema.RequestGraphicsSnapshot,
) void {
    const active = attachments.find(request.pane_id) orelse {
        metrics.stale_client_messages += 1;
        return;
    };
    active.resetGraphics();
}

pub fn configureGraphics(
    attachments: *AttachmentStore,
    shared_graphics: *bool,
    configure: schema.ConfigureGraphics,
) void {
    shared_graphics.* = configure.shared;
    attachments.configureGraphics(configure.shared);
}

pub fn requestRuntimeState(delivery: *Delivery) void {
    delivery.requestRuntimeState();
}

pub fn graphicsCredit(
    attachments: *AttachmentStore,
    metrics: *RuntimeMetrics,
    credit: schema.GraphicsCredit,
) void {
    const active = attachments.find(credit.pane_id) orelse {
        metrics.stale_client_messages += 1;
        return;
    };
    const bytes = std.math.cast(usize, credit.bytes) orelse {
        metrics.stale_client_messages += 1;
        return;
    };
    if (!active.grantGraphicsCredit(bytes)) metrics.stale_client_messages += 1;
}

pub fn frameAck(
    io: Io,
    attachments: *AttachmentStore,
    metrics: *RuntimeMetrics,
    ack: schema.FrameAck,
) void {
    const active = attachments.find(ack.pane_id) orelse {
        metrics.stale_client_messages += 1;
        return;
    };
    const elapsed = active.acknowledgeFrame(
        ack.frame_id,
        diagnostics.now(io),
    ) orelse {
        metrics.stale_client_messages += 1;
        return;
    };
    if (comptime diagnostics.enabled) metrics.ack.observe(elapsed);
}

pub fn requestSnapshot(
    attachments: *AttachmentStore,
    metrics: *RuntimeMetrics,
    request: schema.RequestSnapshot,
) void {
    const active = attachments.find(request.pane_id) orelse {
        metrics.stale_client_messages += 1;
        return;
    };
    active.requestCellSnapshot();
}

pub fn detachPane(
    attachments: *AttachmentStore,
    metrics: *RuntimeMetrics,
    client: common.ClientKey,
    geometry: common.Geometry,
    detach: schema.DetachPane,
) void {
    const detached_workspace: ?schema.WorkspaceLocation =
        if (attachments.find(detach.pane_id)) |active|
            active.pane.location.workspace
        else
            null;
    if (!attachments.detach(detach.pane_id)) {
        metrics.stale_client_messages += 1;
    } else if (detached_workspace) |left| {
        attachments.forgetWorkspaceIfEmpty();
        if (!attachments.observes(left)) geometry.release(geometry.context, client, left);
    }
}
