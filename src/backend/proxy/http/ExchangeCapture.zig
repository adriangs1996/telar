const std = @import("std");
const ResponseHead = @import("ResponseHead.zig");
const connection = @import("connection.zig");
const types = @import("types.zig");
const RequestHead = @import("RequestHead.zig");
const ExchangeCapture = @This();

body_calls: std.atomic.Value(u32) = .init(0),
response_calls: std.atomic.Value(u32) = .init(0),
body_started: ?*std.Io.Queue(u8) = null,
body_release: ?*std.Io.Queue(u8) = null,
response_started: ?*std.Io.Queue(u8) = null,
response_release: ?*std.Io.Queue(u8) = null,
body_result: bool = true,
body_canceled: std.atomic.Value(bool) = .init(false),
response_canceled: std.atomic.Value(bool) = .init(false),
response: ?ResponseHead = connection.testingResponse(200, .final, .keep_alive),

pub fn io(_: *ExchangeCapture) std.Io {
    return std.testing.io;
}

pub fn relayBody(self: *ExchangeCapture, _: types.BodyPlan) bool {
    _ = self.body_calls.fetchAdd(1, .monotonic);

    if (self.response_started) |started| {
        _ = started.getOne(std.testing.io) catch return false;
    }

    if (self.body_started) |started| {
        started.putOneUncancelable(std.testing.io, 0) catch return false;
    }

    if (self.body_release) |release| {
        _ = release.getOne(std.testing.io) catch {
            self.body_canceled.store(true, .monotonic);
            return false;
        };
    }

    return self.body_result;
}

pub fn relayResponse(self: *ExchangeCapture, _: RequestHead) ?ResponseHead {
    _ = self.response_calls.fetchAdd(1, .monotonic);

    if (self.body_started) |started| {
        _ = started.getOne(std.testing.io) catch return null;
    }

    if (self.response_started) |started| {
        started.putOneUncancelable(std.testing.io, 0) catch return null;
    }

    if (self.response_release) |release| {
        _ = release.getOne(std.testing.io) catch {
            self.response_canceled.store(true, .monotonic);
            return null;
        };
    }

    return self.response;
}
