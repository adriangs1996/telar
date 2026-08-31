//! Periodic host-metrics sampling coordination.

const std = @import("std");
const system_metrics = @import("system_metrics.zig");

pub const Resources = struct {
    sampler: *system_metrics.Sampler,
};

/// Defines timer rearming, host sampling, and client delivery bound by the
/// runtime instance.
///
/// ```zig
/// const port: RuntimePort(Context) = .{ ... };
/// ```
pub fn RuntimePort(comptime Context: type) type {
    return struct {
        rearm_tick: *const fn (*Context) anyerror!void,
        sample: *const fn (*Context, *system_metrics.Sampler) void,
        pump_clients: *const fn (*Context) void,
    };
}

/// Creates a statically dispatched system-metrics coordinator.
///
/// ```zig
/// const SystemMetricsCoordinator = Coordinator(Context, port);
/// ```
pub fn Coordinator(comptime Context: type, comptime port: RuntimePort(Context)) type {
    return struct {
        const Self = @This();

        context: *Context,
        resources: Resources,

        /// Binds periodic sampling effects to one runtime-owned sampler.
        ///
        /// ```zig
        /// var coordinator = SystemMetricsCoordinator.init(&context, resources);
        /// ```
        pub fn init(context: *Context, resources: Resources) Self {
            return .{ .context = context, .resources = resources };
        }

        /// Rearms a successful timer before sampling the host. Tick failures
        /// stop this cycle silently; rearm failures propagate without sampling;
        /// every completed sample leaves one client delivery opportunity.
        ///
        /// ```zig
        /// try coordinator.handle(tick_result);
        /// ```
        pub fn handle(coordinator: *Self, result: anyerror!void) !void {
            result catch return;
            try port.rearm_tick(coordinator.context);

            port.sample(coordinator.context, coordinator.resources.sampler);
            port.pump_clients(coordinator.context);
        }
    };
}

const Step = enum {
    rearm_tick,
    sample,
    pump_clients,
};

const Capture = struct {
    steps: [3]Step = undefined,
    len: usize = 0,
    rearm_failure: bool = false,
    expected_sampler: ?*const system_metrics.Sampler = null,
    sample_received_expected_sampler: bool = false,
    update_sample: bool = false,
    pump_revision: ?u64 = null,

    fn record(capture: *Capture, step: Step) void {
        std.debug.assert(capture.len < capture.steps.len);
        capture.steps[capture.len] = step;
        capture.len += 1;
    }

    fn rearmTick(capture: *Capture) !void {
        capture.record(.rearm_tick);

        if (capture.rearm_failure) {
            return error.SchedulerUnavailable;
        }
    }

    fn sample(capture: *Capture, sampler: *system_metrics.Sampler) void {
        capture.record(.sample);
        capture.sample_received_expected_sampler = sampler == capture.expected_sampler.?;

        if (capture.update_sample) {
            sampler.latest = .{
                .cpu_percent = 25,
                .memory_used_decigib = 40,
                .battery_percent = 75,
            };
            sampler.revision = 9;
        }
    }

    fn pumpClients(capture: *Capture) void {
        capture.record(.pump_clients);
        capture.pump_revision = capture.expected_sampler.?.revision;
    }
};

const test_port: RuntimePort(Capture) = .{
    .rearm_tick = Capture.rearmTick,
    .sample = Capture.sample,
    .pump_clients = Capture.pumpClients,
};

const TestCoordinator = Coordinator(Capture, test_port);

const Fixture = struct {
    sampler: system_metrics.Sampler = .{},
    capture: Capture = .{},

    fn coordinator(fixture: *Fixture) TestCoordinator {
        fixture.capture.expected_sampler = &fixture.sampler;
        return TestCoordinator.init(&fixture.capture, .{ .sampler = &fixture.sampler });
    }
};

fn expectSteps(capture: *const Capture, expected: []const Step) !void {
    try std.testing.expectEqualSlices(Step, expected, capture.steps[0..capture.len]);
}

test "a failed timer result stops without rearming or sampling" {
    var fixture: Fixture = .{};
    var coordinator = fixture.coordinator();

    try coordinator.handle(error.TimerFailed);

    try expectSteps(&fixture.capture, &.{});
    try std.testing.expectEqual(@as(u64, 1), fixture.sampler.revision);
}

test "rearm failure propagates before sampling or client delivery" {
    var fixture: Fixture = .{};
    fixture.capture.rearm_failure = true;
    var coordinator = fixture.coordinator();

    try std.testing.expectError(error.SchedulerUnavailable, coordinator.handle({}));

    try expectSteps(&fixture.capture, &.{.rearm_tick});
    try std.testing.expectEqual(@as(u64, 1), fixture.sampler.revision);
}

test "a completed sample is visible before clients are pumped" {
    var fixture: Fixture = .{};
    fixture.capture.update_sample = true;
    var coordinator = fixture.coordinator();

    try coordinator.handle({});

    try expectSteps(&fixture.capture, &.{ .rearm_tick, .sample, .pump_clients });
    try std.testing.expect(fixture.capture.sample_received_expected_sampler);
    try std.testing.expectEqual(@as(?u64, 9), fixture.capture.pump_revision);
}

test "a sample without new values still leaves a delivery opportunity" {
    var fixture: Fixture = .{};
    var coordinator = fixture.coordinator();

    try coordinator.handle({});

    try expectSteps(&fixture.capture, &.{ .rearm_tick, .sample, .pump_clients });
    try std.testing.expect(fixture.capture.sample_received_expected_sampler);
    try std.testing.expectEqual(@as(?u64, 1), fixture.capture.pump_revision);
}
