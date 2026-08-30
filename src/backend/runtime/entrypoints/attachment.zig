//! Entrypoints for one client's disposable pane attachments.

const std = @import("std");
const core = @import("telar-core");
const attachment_mod = @import("../attachment.zig");
const delivery_mod = @import("../delivery.zig");
const telemetry_mod = @import("../telemetry.zig");

const AttachmentStore = attachment_mod.AttachmentStore;
const Delivery = delivery_mod.Delivery;
const RuntimeMetrics = telemetry_mod.RuntimeMetrics;
const schema = core.schema;

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
