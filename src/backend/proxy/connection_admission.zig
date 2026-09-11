//! Bounded ownership transfer for accepted proxy connections.

const std = @import("std");

pub const Io = std.Io;

pub const SlotSnapshot = @import("SlotSnapshot.zig");

pub const Slots = @import("Slots.zig");

pub const Port = @import("GenericConnectionAdmissionPort.zig").Type;

pub const Runner = @import("GenericRunner.zig").Type;

pub const Step = enum {
    accept,
    acquire,
    start,
    release,
    close,
    cancel,
};

pub const AcceptResult = union(enum) {
    stream: u8,
    transient_failure,
    listener_closed,
    canceled,
};

const Capture = @import("ConnectionAdmissionCapture.zig");

const test_port: Port(Capture, u8) = .{
    .accept = Capture.accept,
    .acquire = Capture.acquire,
    .start = Capture.start,
    .release = Capture.release,
    .close = Capture.close,
    .cancel = Capture.cancel,
};

const TestRunner = Runner(Capture, u8, test_port);

fn fixture(results: []const AcceptResult) Capture {
    std.debug.assert(results.len <= 4);
    var capture: Capture = .{};
    @memcpy(capture.accepts[0..results.len], results);
    capture.accept_len = results.len;
    return capture;
}

fn expectSteps(capture: *const Capture, expected: []const Step) !void {
    try std.testing.expectEqualSlices(Step, expected, capture.steps[0..capture.len]);
}

test "connection slots never expose a count above their bound" {
    var slots = Slots.init(2);

    try std.testing.expect(slots.acquire());
    try std.testing.expect(slots.acquire());
    try std.testing.expect(!slots.acquire());
    try std.testing.expectEqual(SlotSnapshot{ .active = 2, .limit_drops = 1 }, slots.snapshot());

    slots.release();
    try std.testing.expect(slots.acquire());
    try std.testing.expectEqual(SlotSnapshot{ .active = 2, .limit_drops = 1 }, slots.snapshot());

    slots.release();
    slots.release();
    try std.testing.expectEqual(SlotSnapshot{ .active = 0, .limit_drops = 1 }, slots.snapshot());
}

test "a zero connection limit rejects and counts every attempt" {
    var slots = Slots.init(0);

    try std.testing.expect(!slots.acquire());
    try std.testing.expect(!slots.acquire());
    try std.testing.expectEqual(SlotSnapshot{ .active = 0, .limit_drops = 2 }, slots.snapshot());
}

test "listener closure stops and cancels the worker group" {
    var capture = fixture(&.{.listener_closed});

    try TestRunner.run(&capture);

    try expectSteps(&capture, &.{ .accept, .cancel });
}

test "listener cancellation propagates after canceling workers" {
    var capture = fixture(&.{.canceled});

    try std.testing.expectError(error.Canceled, TestRunner.run(&capture));

    try expectSteps(&capture, &.{ .accept, .cancel });
}

test "transient accept failure retries without touching admission state" {
    var capture = fixture(&.{ .transient_failure, .{ .stream = 7 }, .listener_closed });

    try TestRunner.run(&capture);

    try expectSteps(&capture, &.{ .accept, .accept, .acquire, .start, .accept, .cancel });
    try std.testing.expectEqual(@as(?u8, 7), capture.started_stream);
    try std.testing.expect(capture.closed_stream == null);
    try std.testing.expectEqual(@as(usize, 0), capture.releases);
}

test "capacity rejection closes the stream without starting a worker" {
    var capture = fixture(&.{ .{ .stream = 9 }, .listener_closed });
    capture.slot_available = false;

    try TestRunner.run(&capture);

    try expectSteps(&capture, &.{ .accept, .acquire, .close, .accept, .cancel });
    try std.testing.expectEqual(@as(?u8, 9), capture.closed_stream);
    try std.testing.expect(capture.started_stream == null);
    try std.testing.expectEqual(@as(usize, 0), capture.releases);
}

test "worker scheduling failure releases the slot before closing the stream" {
    var capture = fixture(&.{ .{ .stream = 11 }, .listener_closed });
    capture.start_fails = true;

    try TestRunner.run(&capture);

    try expectSteps(&capture, &.{ .accept, .acquire, .start, .release, .close, .accept, .cancel });
    try std.testing.expectEqual(@as(?u8, 11), capture.closed_stream);
    try std.testing.expectEqual(@as(usize, 1), capture.releases);
}
