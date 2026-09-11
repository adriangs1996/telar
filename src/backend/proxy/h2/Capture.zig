const std = @import("std");
const StatsType = @import("Stats.zig");
const connection = @import("connection.zig");
const Settings = @import("Settings.zig");
const relay = @import("relay.zig");
const Capture = @This();

request_started: ?*std.Io.Queue(u8) = null,
request_release: ?*std.Io.Queue(u8) = null,
request_canceled: std.atomic.Value(bool) = .init(false),
response_saw_request: bool = false,
response_saw_shared_settings: bool = false,
request_stats: StatsType = .{},
response_stats: StatsType = .{},
steps: [3]connection.Step = undefined,
step_len: usize = 0,

pub fn io(_: *Capture) std.Io {
    return std.testing.io;
}

pub fn relayRequest(capture: *Capture, settings: *Settings) StatsType {
    settings.child.max_frame_size.store(32 * 1024, .seq_cst);

    if (capture.request_started) |started| {
        started.putOneUncancelable(std.testing.io, 0) catch return capture.request_stats;
    }

    if (capture.request_release) |release| {
        _ = release.getOne(std.testing.io) catch {
            capture.request_canceled.store(true, .release);
        };
    }

    return capture.request_stats;
}

pub fn relayResponse(capture: *Capture, settings: *Settings) StatsType {
    if (capture.request_started) |started| {
        _ = started.getOne(std.testing.io) catch return capture.response_stats;
        capture.response_saw_request = true;
    }

    capture.response_saw_shared_settings = settings.child.max_frame_size.load(.seq_cst) == 32 * 1024;
    return capture.response_stats;
}

pub fn recordDecodeFailure(capture: *Capture, direction: relay.Direction) void {
    capture.record(switch (direction) {
        .request => .request_decode_failure,
        .response => .response_decode_failure,
    });
}

pub fn settle(capture: *Capture) void {
    capture.record(.settle);
}

fn record(capture: *Capture, step: connection.Step) void {
    std.debug.assert(capture.step_len < capture.steps.len);
    capture.steps[capture.step_len] = step;
    capture.step_len += 1;
}
