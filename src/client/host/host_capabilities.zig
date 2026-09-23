//! Host capabilities: records what the host terminal answered and reconciles
//! the features that depend on it.
const data = @import("model");
const host_resize = @import("host_resize.zig");
const Client = @import("../execution/Client.zig");

/// Applies a semantic terminal response through the same resource policy.
/// Example: `_ = try host_capabilities.observeHostCapability(client, observation);`
pub fn observeHostCapability(client: *Client, observation: data.HostCapabilityObservation) !?data.HostCommit {
    const commit = try client.model.observeHostCapability(observation) orelse return null;

    try host_resize.deliverHostCommit(client, commit);

    return commit;
}

/// Resolves geometry when a probe settles a complete set of capabilities.
/// Example: `_ = try host_capabilities.reconcileHostCapabilities(client, capabilities);`
pub fn reconcileHostCapabilities(client: *Client, capabilities: data.HostCapabilities) !?data.HostCommit {
    var size = client.model.host.host_size;
    const cell_size = capabilities.cellSize(size.cols, size.rows);
    size.cell_width_px = cell_size.width;
    size.cell_height_px = cell_size.height;

    return host_resize.applyHostUpdate(
        client,
        .{
            .size = size,
            .capabilities = capabilities,
        },
    );
}
