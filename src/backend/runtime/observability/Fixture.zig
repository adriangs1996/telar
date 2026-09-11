const Fixture = @This();
const system_metrics = @import("system_metrics.zig");
const Capture = @import("SystemMetricsCoordinatorCapture.zig");
const source_namespace = @import("system_metrics_coordinator.zig");
sampler: system_metrics.Sampler = .{},
pending: bool = false,
capture: Capture = .{},

pub fn coordinator(fixture: *Fixture) source_namespace.TestCoordinator {
    return .init(&fixture.capture, .{ .sampler = &fixture.sampler, .pending = &fixture.pending });
}
