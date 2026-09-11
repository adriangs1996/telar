const Handler = @This();
const client_model = @import("../../root.zig").model;
const Effects = @import("HostCapabilitiesEffects.zig");
model: *client_model.Model,
effects: Effects,

/// Commits one semantic host response before synchronizing resources.
///
/// ```zig
/// const commit = try handler.observe(observation) orelse return;
/// ```
pub fn observe(handler: *Handler, observation: client_model.HostCapabilityObservation) !?client_model.HostCommit {
    const commit = try handler.model.observeHostCapability(observation) orelse return null;

    try handler.effects.deliver(handler.effects.context, commit);
    return commit;
}

/// Commits a complete adapter observation before delivering resources.
/// Example: `_ = try handler.reconcile(capabilities);`.
pub fn reconcile(handler: *Handler, capabilities: client_model.HostCapabilities) !?client_model.HostCommit {
    var size = handler.model.hostSize();
    const cell_size = capabilities.cellSize(size.cols, size.rows);
    size.cell_width_px = cell_size.width;
    size.cell_height_px = cell_size.height;
    const commit = try handler.model.reconcileHost(.{ .capabilities = capabilities, .size = size }) orelse return null;

    try handler.effects.deliver(handler.effects.context, commit);
    return commit;
}
