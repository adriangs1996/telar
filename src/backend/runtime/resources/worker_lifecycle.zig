//! Start, stop, join and destroy for one runtime-owned service worker.
//!
//! A service lives at a stable heap address, its worker runs as one
//! concurrent task, and teardown always closes the service's queues before
//! joining the worker and destroying the state. Startup failure releases the
//! transferred state so the caller owns nothing on error.

const std = @import("std");

pub const Port = @import("GenericPort.zig").Type;

pub const Lifecycle = @import("GenericLifecycle.zig").Type;

pub const Step = enum {
    start,
    close,
    join,
    destroy,
};

const Capture = @import("Capture.zig");

const FakeState = @import("FakeState.zig");

const FakeWorker = @import("FakeWorker.zig");

fn startFakeWorker(state: *FakeState) !FakeWorker {
    state.capture.record(.start);

    if (state.capture.start_fails) {
        return error.WorkerUnavailable;
    }

    return .{};
}

fn closeFakeQueues(state: *FakeState) void {
    std.debug.assert(!state.capture.joined);
    state.capture.record(.close);
    state.capture.closed = true;
}

fn joinFakeWorker(state: *FakeState, _: *FakeWorker) void {
    std.debug.assert(state.capture.closed);
    state.capture.record(.join);
    state.capture.joined = true;
}

fn destroyFakeState(state: *FakeState) void {
    if (!state.capture.start_fails) {
        std.debug.assert(state.capture.joined);
    }

    state.capture.record(.destroy);
}

const test_port: Port(FakeState, FakeWorker) = .{
    .start = startFakeWorker,
    .close = closeFakeQueues,
    .join = joinFakeWorker,
    .destroy = destroyFakeState,
};

const TestLifecycle = Lifecycle(FakeState, FakeWorker, test_port);

fn expectSteps(capture: *const Capture, expected: []const Step) !void {
    try std.testing.expectEqualSlices(Step, expected, capture.steps[0..capture.len]);
}

test "worker startup failure releases transferred service ownership" {
    var capture: Capture = .{ .start_fails = true };
    var state: FakeState = .{ .capture = &capture };

    try std.testing.expectError(error.WorkerUnavailable, TestLifecycle.start(&state));
    try expectSteps(&capture, &.{ .start, .destroy });
}

test "shutdown closes queues before joining and destroying the service" {
    var capture: Capture = .{};
    var state: FakeState = .{ .capture = &capture };
    var lifecycle = try TestLifecycle.start(&state);

    lifecycle.deinit();

    try expectSteps(&capture, &.{ .start, .close, .join, .destroy });
}
