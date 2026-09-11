const SamplerType = @import("Sampler.zig");
const SystemMetricsCoordinatorCapture = @import("SystemMetricsCoordinatorCapture.zig");
const system_metrics_coordinator = @import("system_metrics_coordinator.zig");
const Fixture = @This();

sampler: SamplerType = .{},
pending: bool = false,
capture: SystemMetricsCoordinatorCapture = .{},

pub fn coordinator(fixture: *Fixture) system_metrics_coordinator.TestCoordinator {
    return .init(&fixture.capture, .{ .sampler = &fixture.sampler, .pending = &fixture.pending });
}
