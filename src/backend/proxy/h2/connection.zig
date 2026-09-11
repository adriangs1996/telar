//! Ownership of one bidirectional HTTP/2 relay.

const GenericConnectionPort = @import("GenericConnectionPort.zig").Type;
const GenericConnection = @import("GenericConnection.zig").Type;
const Capture = @import("Capture.zig");
const std = @import("std");

pub const Settings = @import("Settings.zig");

pub const Step = enum {
    response_decode_failure,
    request_decode_failure,
    settle,
};

const test_port: GenericConnectionPort(Capture) = .{
    .io = Capture.io,
    .relay_request = Capture.relayRequest,
    .relay_response = Capture.relayResponse,
    .record_decode_failure = Capture.recordDecodeFailure,
    .settle = Capture.settle,
};

const TestConnection = GenericConnection(Capture, test_port);

test "response completion cancels the unfinished request relay before settlement" {
    var started_storage: [1]u8 = undefined;
    var release_storage: [1]u8 = undefined;
    var started: std.Io.Queue(u8) = .init(&started_storage);
    var release: std.Io.Queue(u8) = .init(&release_storage);
    var capture: Capture = .{
        .request_started = &started,
        .request_release = &release,
    };

    TestConnection.run(&capture);

    try std.testing.expect(capture.response_saw_request);
    try std.testing.expect(capture.response_saw_shared_settings);
    try std.testing.expect(capture.request_canceled.load(.acquire));
    try std.testing.expectEqualSlices(Step, &.{.settle}, capture.steps[0..capture.step_len]);
}

test "both decode failures are recorded before connection settlement" {
    var started_storage: [1]u8 = undefined;
    var started: std.Io.Queue(u8) = .init(&started_storage);
    var capture: Capture = .{
        .request_started = &started,
        .request_stats = .{ .decode_failed = true },
        .response_stats = .{ .decode_failed = true },
    };

    TestConnection.run(&capture);

    try std.testing.expectEqualSlices(
        Step,
        &.{ .response_decode_failure, .request_decode_failure, .settle },
        capture.steps[0..capture.step_len],
    );
}
