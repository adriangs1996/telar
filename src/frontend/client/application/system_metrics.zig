//! Application use case for reconciling runtime host-health metrics.

const std = @import("std");
const client_model = @import("../model.zig");

pub const ReconcileSystemMetricsHandler = struct {
    model: *client_model.Model,

    /// Stores one newer metrics replica without deciding presentation.
    ///
    /// ```zig
    /// const commit = try handler.execute(metrics) orelse return;
    /// ```
    pub fn execute(handler: *ReconcileSystemMetricsHandler, metrics: client_model.SystemMetrics) !?client_model.SystemMetricsCommit {
        return handler.model.reconcileSystemMetrics(metrics);
    }
};

test "ReconcileSystemMetricsHandler commits only newer valid metrics" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var handler: ReconcileSystemMetricsHandler = .{ .model = &model };
    const metrics: client_model.SystemMetrics = .{
        .runtime_revision = 7,
        .cpu_percent = 42,
        .memory_used_decigib = 92,
        .battery_percent = 84,
    };

    const commit = (try handler.execute(metrics)).?;

    try std.testing.expectEqual(@as(u64, 7), commit.runtime_revision);
    try std.testing.expectEqual(@as(u64, 1), commit.system_metrics_revision);
    try std.testing.expectEqualDeep(metrics, model.systemMetrics().?);
    try std.testing.expectEqual(client_model.Version{ .system_metrics = 1 }, model.version());
    try std.testing.expect((try handler.execute(metrics)) == null);
    try std.testing.expectEqual(client_model.Version{ .system_metrics = 1 }, model.version());
}

test "ReconcileSystemMetricsHandler preserves committed metrics after rejection" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var handler: ReconcileSystemMetricsHandler = .{ .model = &model };
    const metrics: client_model.SystemMetrics = .{
        .runtime_revision = 1,
        .cpu_percent = 42,
        .memory_used_decigib = 92,
        .battery_percent = null,
    };
    _ = try handler.execute(metrics);

    try std.testing.expectError(error.InvalidMetricsValue, handler.execute(.{
        .runtime_revision = 2,
        .cpu_percent = 101,
        .memory_used_decigib = 92,
        .battery_percent = null,
    }));
    try std.testing.expectEqualDeep(metrics, model.systemMetrics().?);
    try std.testing.expectEqual(client_model.Version{ .system_metrics = 1 }, model.version());
}
