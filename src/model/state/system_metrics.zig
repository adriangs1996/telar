//! Host metrics the runtime samples, reconciled into the client model.

const SystemMetricsCommit = @import("SystemMetricsCommit.zig");
const SystemMetrics = @import("SystemMetrics.zig");
const ClientModel = @import("ClientModel.zig");

/// Commits one newer host-health replica. Invalid newer values preserve
/// the last usable metrics and their local version.
///
/// ```zig
/// const commit = try system_metrics.reconcile(model, metrics) orelse return;
/// ```
pub fn reconcile(model: *ClientModel, metrics: SystemMetrics) !?SystemMetricsCommit {
    if (metrics.runtime_revision == 0) {
        return error.InvalidMetricsRevision;
    }

    const current_revision = if (model.system_metrics) |current| current.runtime_revision else 0;
    if (metrics.runtime_revision <= current_revision) {
        return null;
    }
    if (metrics.cpu_percent > 100) {
        return error.InvalidMetricsValue;
    }
    if (metrics.battery_percent) |battery| {
        if (battery > 100) {
            return error.InvalidMetricsValue;
        }
    }

    model.system_metrics = metrics;
    model.system_metrics_revision +%= 1;

    return .{
        .runtime_revision = metrics.runtime_revision,
        .system_metrics_revision = model.system_metrics_revision,
    };
}
