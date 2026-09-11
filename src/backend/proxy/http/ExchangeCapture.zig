const ExchangeCapture = @This();
const std = @import("std");
const types = @import("types.zig");
const source_namespace = @import("connection.zig");
body_calls: std.atomic.Value(u32) = .init(0),
response_calls: std.atomic.Value(u32) = .init(0),
body_started: ?*std.Io.Queue(u8) = null,
body_release: ?*std.Io.Queue(u8) = null,
response_started: ?*std.Io.Queue(u8) = null,
response_release: ?*std.Io.Queue(u8) = null,
body_result: bool = true,
body_canceled: std.atomic.Value(bool) = .init(false),
response_canceled: std.atomic.Value(bool) = .init(false),
response: ?types.ResponseHead = source_namespace.testingResponse(200, .final, .keep_alive),

pub fn io(_: *ExchangeCapture) std.Io {
    return std.testing.io;
}

pub fn relayBody(capture: *ExchangeCapture, _: types.BodyPlan) bool {
    _ = capture.body_calls.fetchAdd(1, .monotonic);

    if (capture.response_started) |started| {
        _ = started.getOne(std.testing.io) catch return false;
    }

    if (capture.body_started) |started| {
        started.putOneUncancelable(std.testing.io, 0) catch return false;
    }

    if (capture.body_release) |release| {
        _ = release.getOne(std.testing.io) catch {
            capture.body_canceled.store(true, .monotonic);
            return false;
        };
    }

    return capture.body_result;
}

pub fn relayResponse(capture: *ExchangeCapture, _: types.RequestHead) ?types.ResponseHead {
    _ = capture.response_calls.fetchAdd(1, .monotonic);

    if (capture.body_started) |started| {
        _ = started.getOne(std.testing.io) catch return null;
    }

    if (capture.response_started) |started| {
        started.putOneUncancelable(std.testing.io, 0) catch return null;
    }

    if (capture.response_release) |release| {
        _ = release.getOne(std.testing.io) catch {
            capture.response_canceled.store(true, .monotonic);
            return null;
        };
    }

    return capture.response;
}
