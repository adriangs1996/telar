//! Entrypoints for one client's disposable pane attachments.

const std = @import("std");
const vt = @import("ghostty-vt");
const core = @import("telar-core");
const attachment_mod = @import("../attachment.zig");
const delivery_mod = @import("../delivery.zig");
const telemetry_mod = @import("../telemetry.zig");

const Io = std.Io;
const AttachmentStore = attachment_mod.AttachmentStore;
const Delivery = delivery_mod.Delivery;
const RuntimeMetrics = telemetry_mod.RuntimeMetrics;
const schema = core.schema;
const diagnostics = core.diagnostics;

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
