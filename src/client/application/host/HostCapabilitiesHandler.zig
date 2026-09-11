const ModelType = @import("../../model/Model.zig");
const HostCapabilitiesEffects = @import("HostCapabilitiesEffects.zig");
const types = @import("../../model/types.zig");
const HostCommitType = @import("../../model/HostCommit.zig");
const HostCapabilitiesType = @import("../../model/HostCapabilities.zig");
const Handler = @This();

model: *ModelType,
effects: HostCapabilitiesEffects,

/// Commits one semantic host response before synchronizing resources.
///
/// ```zig
/// const commit = try handler.observe(observation) orelse return;
/// ```
pub fn observe(handler: *Handler, observation: types.HostCapabilityObservation) !?HostCommitType {
    const commit = try handler.model.observeHostCapability(observation) orelse return null;

    try handler.effects.deliver(handler.effects.context, commit);
    return commit;
}

/// Commits a complete adapter observation before delivering resources.
/// Example: `_ = try handler.reconcile(capabilities);`.
pub fn reconcile(handler: *Handler, capabilities: HostCapabilitiesType) !?HostCommitType {
    var size = handler.model.hostSize();
    const cell_size = capabilities.cellSize(size.cols, size.rows);
    size.cell_width_px = cell_size.width;
    size.cell_height_px = cell_size.height;
    const commit = try handler.model.reconcileHost(.{ .capabilities = capabilities, .size = size }) orelse return null;

    try handler.effects.deliver(handler.effects.context, commit);
    return commit;
}
