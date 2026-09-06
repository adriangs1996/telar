//! Single-flight host sampling with value-owned worker state.
const std = @import("std");
const system_metrics = @import("system_metrics.zig");

pub const Resources = struct {
    sampler: *system_metrics.Sampler,
    pending: *bool,
};

/// Example: `const port: RuntimePort(Context) = .{ ... };`.
pub fn RuntimePort(comptime Context: type) type {
    return struct {
        rearm_tick: *const fn (*Context) anyerror!void,
        schedule: *const fn (*Context, system_metrics.Sampler) anyerror!void,
        pump_clients: *const fn (*Context) void,
    };
}

/// Example: `const Metrics = Coordinator(Context, port);`.
pub fn Coordinator(comptime Context: type, comptime port: RuntimePort(Context)) type {
    return struct {
        const Self = @This();
        context: *Context,
        resources: Resources,

        /// Example: `var coordinator = Metrics.init(&context, resources);`.
        pub fn init(context: *Context, resources: Resources) Self {
            return .{ .context = context, .resources = resources };
        }

        /// Coalesces timer ticks while the worker owns a sampler copy.
        /// Example: `try coordinator.handle(tick_result);`.
        pub fn handle(coordinator: *Self, result: anyerror!void) !void {
            result catch return;
            try port.rearm_tick(coordinator.context);
            if (coordinator.resources.pending.*) {
                return;
            }

            coordinator.resources.pending.* = true;
            errdefer coordinator.resources.pending.* = false;
            try port.schedule(coordinator.context, coordinator.resources.sampler.*);
        }

        /// Publishes a complete sample; unchanged projections do not pump clients.
        /// Example: `coordinator.complete(sampled);`.
        pub fn complete(coordinator: *Self, sampled: system_metrics.Sampler) void {
            std.debug.assert(coordinator.resources.pending.*);
            const changed = sampled.revision != coordinator.resources.sampler.revision;
            coordinator.resources.pending.* = false;
            coordinator.resources.sampler.* = sampled;
            if (changed) {
                port.pump_clients(coordinator.context);
            }
        }
    };
}

const Capture = struct {
    rearms: usize = 0,
    jobs: usize = 0,
    pumps: usize = 0,
    fail_rearm: bool = false,
    fail_schedule: bool = false,
    owned: system_metrics.Sampler = .{},

    fn rearm(capture: *Capture) !void {
        capture.rearms += 1;
        if (capture.fail_rearm) {
            return error.SchedulerUnavailable;
        }
    }

    fn schedule(capture: *Capture, sampler: system_metrics.Sampler) !void {
        if (capture.fail_schedule) {
            return error.SchedulerUnavailable;
        }

        capture.jobs += 1;
        capture.owned = sampler;
    }

    fn pump(capture: *Capture) void {
        capture.pumps += 1;
    }
};

const TestCoordinator = Coordinator(Capture, .{ .rearm_tick = Capture.rearm, .schedule = Capture.schedule, .pump_clients = Capture.pump });

const Fixture = struct {
    sampler: system_metrics.Sampler = .{},
    pending: bool = false,
    capture: Capture = .{},

    fn coordinator(fixture: *Fixture) TestCoordinator {
        return .init(&fixture.capture, .{ .sampler = &fixture.sampler, .pending = &fixture.pending });
    }
};

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
