//! Ownership transaction for one running proxy service.

const GenericLifecyclePort = @import("GenericLifecyclePort.zig").Type;
const GenericLifecycle = @import("GenericLifecycle.zig").Type;
const FakeService = @import("FakeService.zig");
const FakeWorker = @import("FakeWorker.zig");
const std = @import("std");
const LifecycleCapture = @import("LifecycleCapture.zig");

pub const Step = enum {
    start,
    cancel,
    close,
    destroy,
};

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

const test_port: GenericLifecyclePort(FakeService, FakeWorker) = .{
    .start = startWorker,
    .cancel = cancelWorker,
    .close = closeObservations,
    .destroy = destroyService,
};

const TestLifecycle = GenericLifecycle(FakeService, FakeWorker, test_port);

fn expectSteps(capture: *const LifecycleCapture, expected: []const Step) !void {
    try std.testing.expectEqualSlices(Step, expected, capture.steps[0..capture.len]);
}

test "worker startup failure destroys the transferred service" {
    var capture: LifecycleCapture = .{ .start_fails = true };
    var service: FakeService = .{ .capture = &capture };

    try std.testing.expectError(error.ConcurrencyUnavailable, TestLifecycle.start(&service));

    try expectSteps(&capture, &.{ .start, .destroy });
    try std.testing.expect(capture.destroyed);
}

test "successful startup retains every resource until deinit" {
    var capture: LifecycleCapture = .{};
    var service: FakeService = .{ .capture = &capture };
    var lifecycle = try TestLifecycle.start(&service);

    try expectSteps(&capture, &.{.start});
    try std.testing.expect(!capture.canceled);
    try std.testing.expect(!capture.closed);
    try std.testing.expect(!capture.destroyed);

    lifecycle.deinit();

    try expectSteps(&capture, &.{ .start, .cancel, .close, .destroy });
}
