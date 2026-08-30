//! Ownership transaction for one running proxy service.

const std = @import("std");

/// Defines how a service worker starts and how all of its resources stop.
/// `cancel` must join the worker before `destroy` releases the service.
///
/// ```zig
/// const port: Port(Service, Worker) = .{
///     .start = startWorker,
///     .cancel = cancelWorker,
///     .close = closeObservations,
///     .destroy = destroyService,
/// };
/// ```
pub fn Port(comptime Service: type, comptime Worker: type) type {
    return struct {
        start: *const fn (*Service) anyerror!Worker,
        cancel: *const fn (*Service, *Worker) void,
        close: *const fn (*Service) void,
        destroy: *const fn (*Service) void,
    };
}

/// Creates the owner of one service and its background worker.
///
/// Startup transfers service ownership immediately. If the worker cannot
/// start, the service is destroyed before the error is returned. Shutdown
/// first joins the worker, then closes observations, then destroys the service.
///
/// ```zig
/// const RunningService = Lifecycle(Service, Worker, port);
/// var running = try RunningService.start(service);
/// defer running.deinit();
/// ```
pub fn Lifecycle(comptime Service: type, comptime Worker: type, comptime port: Port(Service, Worker)) type {
    return struct {
        const Self = @This();

        service: *Service,
        worker: Worker,

        /// Starts the worker and assumes ownership of `service` on every path.
        ///
        /// ```zig
        /// var running = try RunningService.start(service);
        /// ```
        pub fn start(service: *Service) !Self {
            errdefer port.destroy(service);

            return .{
                .service = service,
                .worker = try port.start(service),
            };
        }

        /// Joins the worker and releases every resource owned by this lifecycle.
        ///
        /// ```zig
        /// running.deinit();
        /// ```
        pub fn deinit(lifecycle: *Self) void {
            port.cancel(lifecycle.service, &lifecycle.worker);
            port.close(lifecycle.service);
            port.destroy(lifecycle.service);
        }
    };
}

const Step = enum {
    start,
    cancel,
    close,
    destroy,
};

const Capture = struct {
    steps: [4]Step = undefined,
    len: usize = 0,
    start_fails: bool = false,
    canceled: bool = false,
    closed: bool = false,
    destroyed: bool = false,

    fn record(capture: *Capture, step: Step) void {
        std.debug.assert(capture.len < capture.steps.len);
        capture.steps[capture.len] = step;
        capture.len += 1;
    }
};

const FakeService = struct {
    capture: *Capture,
};

const FakeWorker = struct {};

fn startWorker(service: *FakeService) !FakeWorker {
    service.capture.record(.start);

    if (service.capture.start_fails) {
        return error.ConcurrencyUnavailable;
    }

    return .{};
}

fn cancelWorker(service: *FakeService, _: *FakeWorker) void {
    std.debug.assert(!service.capture.closed);
    std.debug.assert(!service.capture.destroyed);
    service.capture.record(.cancel);
    service.capture.canceled = true;
}

fn closeObservations(service: *FakeService) void {
    std.debug.assert(service.capture.canceled);
    std.debug.assert(!service.capture.destroyed);
    service.capture.record(.close);
    service.capture.closed = true;
}

fn destroyService(service: *FakeService) void {
    if (!service.capture.start_fails) {
        std.debug.assert(service.capture.closed);
    }

    service.capture.record(.destroy);
    service.capture.destroyed = true;
}

const test_port: Port(FakeService, FakeWorker) = .{
    .start = startWorker,
    .cancel = cancelWorker,
    .close = closeObservations,
    .destroy = destroyService,
};

const TestLifecycle = Lifecycle(FakeService, FakeWorker, test_port);

fn expectSteps(capture: *const Capture, expected: []const Step) !void {
    try std.testing.expectEqualSlices(Step, expected, capture.steps[0..capture.len]);
}

test "worker startup failure destroys the transferred service" {
    var capture: Capture = .{ .start_fails = true };
    var service: FakeService = .{ .capture = &capture };

    try std.testing.expectError(error.ConcurrencyUnavailable, TestLifecycle.start(&service));

    try expectSteps(&capture, &.{ .start, .destroy });
    try std.testing.expect(capture.destroyed);
}

test "successful startup retains every resource until deinit" {
    var capture: Capture = .{};
    var service: FakeService = .{ .capture = &capture };
    var lifecycle = try TestLifecycle.start(&service);

    try expectSteps(&capture, &.{.start});
    try std.testing.expect(!capture.canceled);
    try std.testing.expect(!capture.closed);
    try std.testing.expect(!capture.destroyed);

    lifecycle.deinit();

    try expectSteps(&capture, &.{ .start, .cancel, .close, .destroy });
}
