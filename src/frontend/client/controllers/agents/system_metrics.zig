//! Adapts runtime host-health messages to the client application boundary.

const core = @import("telar-core");
const client_model = @import("../../model/root.zig");

const Client = @import("../../client.zig");
const schema = core.schema;

/// Maps one validated wire value into the model-owned metrics replica.
///
/// ```zig
/// _ = try apply(client, message);
/// ```
pub fn apply(client: *Client, message: schema.SystemMetrics) !?client_model.SystemMetricsCommit {
    return client.model.reconcileSystemMetrics(.{
        .runtime_revision = message.revision,
        .cpu_percent = message.cpu_percent,
        .memory_used_decigib = message.memory_used_decigib,
        .battery_percent = if (message.has_battery) message.battery_percent else null,
    });
}
