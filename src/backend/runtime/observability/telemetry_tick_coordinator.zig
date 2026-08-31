//! Coordination for one completed runtime telemetry tick.

const std = @import("std");
const telemetry = @import("telemetry.zig");

const State = telemetry.State;

/// Defines sink availability, sampling, and actor scheduling supplied by the
/// runtime composition root. `format_sample` must return a slice backed by its
/// buffer argument; the write actor owns that storage until completion.
///
/// ```zig
/// const port: RuntimePort(Context) = .{ ... };
/// ```
pub fn RuntimePort(comptime Context: type) type {
    return struct {
        available: *const fn (*Context, *const State) bool,
        disable: *const fn (*Context, *State) void,
        schedule_tick: *const fn (*Context) anyerror!void,
        format_sample: *const fn (*Context, []u8) anyerror![]const u8,
        schedule_write: *const fn (*Context, *State, []const u8) anyerror!void,
    };
}

/// Creates a statically dispatched telemetry-tick coordinator.
///
/// ```zig
/// const TelemetryTickCoordinator = Coordinator(Context, port);
/// ```
pub fn Coordinator(comptime Context: type, comptime port: RuntimePort(Context)) type {
    return struct {
        const Self = @This();

        context: *Context,
        state: *State,

        /// Binds one runtime's sampling effects to its telemetry state.
        ///
        /// ```zig
        /// var coordinator = TelemetryTickCoordinator.init(&context, &state);
        /// ```
        pub fn init(context: *Context, state: *State) Self {
            return .{ .context = context, .state = state };
        }

        /// Rearms the periodic tick before sampling. Samples coalesce while a
        /// write owns the shared buffer; scheduler failures retire the sink,
        /// while formatting failures only discard the current sample.
        ///
        /// ```zig
        /// coordinator.handle(tick_result);
        /// ```
        pub fn handle(coordinator: *Self, result: anyerror!void) void {
            result catch {
                port.disable(coordinator.context, coordinator.state);
                return;
            };

            if (!port.available(coordinator.context, coordinator.state)) {
                return;
            }

            port.schedule_tick(coordinator.context) catch {
                port.disable(coordinator.context, coordinator.state);
                return;
            };

            if (coordinator.state.writePending()) {
                return;
            }

            const line = port.format_sample(coordinator.context, coordinator.state.buffer()) catch return;
            coordinator.state.beginWrite();
            port.schedule_write(coordinator.context, coordinator.state, line) catch {
                coordinator.state.cancelWrite();
                port.disable(coordinator.context, coordinator.state);
            };
        }
    };
}

const Step = enum {
    available,
    tick,
    format,
    write,
    disable,
};

const Capture = struct {
    steps: [5]Step = undefined,
    len: usize = 0,
    sink_available: bool = true,
    failure: ?Step = null,
    line: []const u8 = "sample\n",
    format_buffer_len: usize = 0,
    write_saw_pending: bool = false,
    written_line: []const u8 = "",

    fn record(capture: *Capture, step: Step) !void {
        std.debug.assert(capture.len < capture.steps.len);
        capture.steps[capture.len] = step;
        capture.len += 1;

        if (capture.failure == step) {
            return error.SchedulerUnavailable;
        }
    }

    fn available(capture: *Capture, _: *const State) bool {
        capture.record(.available) catch unreachable;
        return capture.sink_available;
    }

    fn disable(capture: *Capture, _: *State) void {
        capture.record(.disable) catch unreachable;
    }

    fn scheduleTick(capture: *Capture) !void {
        try capture.record(.tick);
    }

    fn formatSample(capture: *Capture, buffer: []u8) ![]const u8 {
        capture.format_buffer_len = buffer.len;
        try capture.record(.format);
        @memcpy(buffer[0..capture.line.len], capture.line);
        return buffer[0..capture.line.len];
    }

    fn scheduleWrite(capture: *Capture, state: *State, line: []const u8) !void {
        capture.write_saw_pending = state.writePending();
        capture.written_line = line;
        try capture.record(.write);
    }
};

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
