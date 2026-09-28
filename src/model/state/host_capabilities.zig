//! What the host terminal or window reported it can do, reconciled into the model.

const model_data = @import("../model.zig");
const ClientModel = @import("ClientModel.zig");

/// Atomically reconciles raw host capabilities and resolved geometry.
///
/// ```zig
/// const commit = try host_capabilities.reconcile(model, update) orelse return;
/// ```
pub fn reconcile(model: *ClientModel, update: model_data.HostUpdate) !?model_data.HostCommit {
    return model.host.reconcileHost(update);
}
