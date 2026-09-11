//! Coordination for one completed runtime telemetry tick.

const std = @import("std");
const telemetry = @import("telemetry.zig");

pub const State = telemetry.State;

pub const RuntimePort = @import("GenericTelemetryTickCoordinatorRuntimePort.zig").Type;

pub const Coordinator = @import("GenericTelemetryTickCoordinatorCoordinator.zig").Type;

pub const Step = enum {
    available,
    tick,
    format,
    write,
    disable,
};

const Capture = @import("TelemetryTickCoordinatorCapture.zig");

const test_port: RuntimePort(Capture) = .{
    .available = Capture.available,
    .disable = Capture.disable,
    .schedule_tick = Capture.scheduleTick,
    .format_sample = Capture.formatSample,
    .schedule_write = Capture.scheduleWrite,
};

const TestCoordinator = Coordinator(Capture, test_port);

fn expectSteps(capture: *const Capture, expected: []const Step) !void {
    try std.testing.expectEqualSlices(Step, expected, capture.steps[0..capture.len]);
}

test "a failed tick retires the sink without scheduling more work" {
    var capture: Capture = .{};
    var state: State = .{};
    state.beginWrite();
    var coordinator = TestCoordinator.init(&capture, &state);

    coordinator.handle(error.TimerFailed);

    try expectSteps(&capture, &.{.disable});
    try std.testing.expect(state.writePending());
}

test "an unavailable sink does not rearm the periodic tick" {
    var capture: Capture = .{ .sink_available = false };
    var state: State = .{};
    var coordinator = TestCoordinator.init(&capture, &state);

    coordinator.handle({});

    try expectSteps(&capture, &.{.available});
}

test "tick scheduling failure retires the sink" {
    var capture: Capture = .{ .failure = .tick };
    var state: State = .{};
    state.beginWrite();
    var coordinator = TestCoordinator.init(&capture, &state);

    coordinator.handle({});

    try expectSteps(&capture, &.{ .available, .tick, .disable });
    try std.testing.expect(state.writePending());
}

test "an in-flight write coalesces the sample after rearming the tick" {
    var capture: Capture = .{};
    var state: State = .{};
    state.beginWrite();
    var coordinator = TestCoordinator.init(&capture, &state);

    coordinator.handle({});

    try expectSteps(&capture, &.{ .available, .tick });
    try std.testing.expect(state.writePending());
}

test "formatting failure discards only the current sample" {
    var capture: Capture = .{ .failure = .format };
    var state: State = .{};
    var coordinator = TestCoordinator.init(&capture, &state);

    coordinator.handle({});

    try expectSteps(&capture, &.{ .available, .tick, .format });
    try std.testing.expect(!state.writePending());
}

test "a formatted sample is borrowed before its write is scheduled" {
    var capture: Capture = .{};
    var state: State = .{};
    var coordinator = TestCoordinator.init(&capture, &state);

    coordinator.handle({});

    try expectSteps(&capture, &.{ .available, .tick, .format, .write });
    try std.testing.expectEqual(telemetry.max_line_bytes, capture.format_buffer_len);
    try std.testing.expect(capture.write_saw_pending);
    try std.testing.expectEqualStrings("sample\n", capture.written_line);
    try std.testing.expect(state.writePending());
}

test "write scheduling failure releases the buffer and retires the sink" {
    var capture: Capture = .{ .failure = .write };
    var state: State = .{};
    var coordinator = TestCoordinator.init(&capture, &state);

    coordinator.handle({});

    try expectSteps(&capture, &.{ .available, .tick, .format, .write, .disable });
    try std.testing.expect(capture.write_saw_pending);
    try std.testing.expect(!state.writePending());
}
