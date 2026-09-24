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

/// Commits one semantic capability observation and its resolved geometry.
///
/// ```zig
/// const commit = try host_capabilities.observe(model, observation) orelse return;
/// ```
pub fn observe(model: *ClientModel, observation: model_data.HostCapabilityObservation) !?model_data.HostCommit {
    return model.host.observeHostCapability(observation);
}
