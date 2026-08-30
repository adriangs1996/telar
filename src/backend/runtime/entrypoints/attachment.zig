//! Entrypoints for one client's disposable pane attachments.

const delivery_mod = @import("../delivery.zig");

const Delivery = delivery_mod.Delivery;

pub fn requestRuntimeState(delivery: *Delivery) void {
    delivery.requestRuntimeState();
}
