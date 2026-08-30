//! Entrypoints for one client's disposable pane attachments.

const core = @import("telar-core");
const attachment_mod = @import("../attachment.zig");
const delivery_mod = @import("../delivery.zig");

const AttachmentStore = attachment_mod.AttachmentStore;
const Delivery = delivery_mod.Delivery;
const schema = core.schema;

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
