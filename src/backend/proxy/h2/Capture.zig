const std = @import("std");
const Stats = @import("Stats.zig");
const connection = @import("connection.zig");
const Settings = @import("Settings.zig");
const relay = @import("relay.zig");
const Capture = @This();

request_started: ?*std.Io.Queue(u8) = null,
request_release: ?*std.Io.Queue(u8) = null,
request_canceled: std.atomic.Value(bool) = .init(false),
response_saw_request: bool = false,
response_saw_shared_settings: bool = false,
request_stats: Stats = .{},
response_stats: Stats = .{},
steps: [3]connection.Step = undefined,
step_len: usize = 0,

pub fn io(_: *Capture) std.Io {
    return std.testing.io;
}

pub fn relayRequest(self: *Capture, settings: *Settings) Stats {
    settings.child.max_frame_size.store(32 * 1024, .seq_cst);

    if (self.request_started) |started| {
        started.putOneUncancelable(std.testing.io, 0) catch return self.request_stats;
    }

    if (self.request_release) |release| {
        _ = release.getOne(std.testing.io) catch {
            self.request_canceled.store(true, .release);
        };
    }

    return self.request_stats;
}

pub fn relayResponse(self: *Capture, settings: *Settings) Stats {
    if (self.request_started) |started| {
        _ = started.getOne(std.testing.io) catch return self.response_stats;
        self.response_saw_request = true;
    }

    self.response_saw_shared_settings = settings.child.max_frame_size.load(.seq_cst) == 32 * 1024;
    return self.response_stats;
}

pub fn recordDecodeFailure(self: *Capture, direction: relay.Direction) void {
    self.record(switch (direction) {
        .request => .request_decode_failure,
        .response => .response_decode_failure,
    });
}

pub fn settle(self: *Capture) void {
    self.record(.settle);
}

fn record(self: *Capture, step: connection.Step) void {
    std.debug.assert(self.step_len < self.steps.len);
    self.steps[self.step_len] = step;
    self.step_len += 1;
}
