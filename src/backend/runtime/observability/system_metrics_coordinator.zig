//! Single-flight host sampling with value-owned worker state.
const std = @import("std");
const system_metrics = @import("system_metrics.zig");

pub const Resources = @import("Resources.zig");

pub const RuntimePort = @import("GenericSystemMetricsCoordinatorRuntimePort.zig").Type;

pub const Coordinator = @import("GenericSystemMetricsCoordinatorCoordinator.zig").Type;

const Capture = @import("SystemMetricsCoordinatorCapture.zig");

pub const TestCoordinator = Coordinator(Capture, .{ .rearm_tick = Capture.rearm, .schedule = Capture.schedule, .pump_clients = Capture.pump });

const Fixture = @import("Fixture.zig");

test "blocked host sampling never queues another sample or pumps clients" {
    var fixture: Fixture = .{};
    var coordinator = fixture.coordinator();
    for (0..100) |_| {
        try coordinator.handle({});
    }
    try std.testing.expectEqual(@as(usize, 100), fixture.capture.rearms);
    try std.testing.expectEqual(@as(usize, 1), fixture.capture.jobs);
    try std.testing.expectEqual(@as(usize, 0), fixture.capture.pumps);
    fixture.capture.owned.revision = 9;
    try std.testing.expectEqual(@as(u64, 1), fixture.sampler.revision);
    coordinator.complete(fixture.capture.owned);
    try std.testing.expectEqual(@as(u64, 9), fixture.sampler.revision);
    try std.testing.expectEqual(@as(usize, 1), fixture.capture.pumps);
    try std.testing.expect(!fixture.pending);
}

test "unchanged samples update previous counters without scanning clients" {
    var fixture: Fixture = .{};
    var coordinator = fixture.coordinator();
    try coordinator.handle({});
    fixture.capture.owned.previous_total = 99;
    coordinator.complete(fixture.capture.owned);
    try std.testing.expectEqual(@as(u64, 99), fixture.sampler.previous_total);
    try std.testing.expectEqual(@as(usize, 0), fixture.capture.pumps);
    try coordinator.handle({});
    try std.testing.expectEqual(@as(usize, 2), fixture.capture.jobs);
}

test "failed timers and scheduling preserve admission for the next tick" {
    var fixture: Fixture = .{};
    var coordinator = fixture.coordinator();
    try coordinator.handle(error.TimerFailed);
    try std.testing.expectEqual(@as(usize, 0), fixture.capture.rearms);
    fixture.capture.fail_rearm = true;
    try std.testing.expectError(error.SchedulerUnavailable, coordinator.handle({}));
    try std.testing.expect(!fixture.pending);
    fixture.capture.fail_rearm = false;
    fixture.capture.fail_schedule = true;
    try std.testing.expectError(error.SchedulerUnavailable, coordinator.handle({}));
    try std.testing.expect(!fixture.pending);
    try std.testing.expectEqual(@as(usize, 0), fixture.capture.jobs);
}
