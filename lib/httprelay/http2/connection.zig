//! Ownership of one bidirectional HTTP/2 relay.

const GenericConnection = @import("GenericConnection.zig").Type;
const Capture = @import("Capture.zig");
const std = @import("std");


pub const Step = enum {
    response_decode_failure,
    request_decode_failure,
    settle,
};

const TestConnection = GenericConnection(Capture);

test "response completion cancels the unfinished request relay before settlement" {
    var started_storage: [1]u8 = undefined;
    var release_storage: [1]u8 = undefined;
    var started: std.Io.Queue(u8) = .init(&started_storage);
    var release: std.Io.Queue(u8) = .init(&release_storage);
    var capture: Capture = .{
        .request_started = &started,
        .request_release = &release,
    };

    TestConnection.run(std.testing.io, &capture);

    try std.testing.expect(capture.response_saw_request);
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

    TestConnection.run(std.testing.io, &capture);

    try std.testing.expectEqualSlices(
        Step,
        &.{ .response_decode_failure, .request_decode_failure, .settle },
        capture.steps[0..capture.step_len],
    );
}
