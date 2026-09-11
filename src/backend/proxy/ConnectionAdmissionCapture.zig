const Capture = @This();
const source_namespace = @import("connection_admission.zig");
const std = @import("std");
steps: [20]source_namespace.Step = undefined,
len: usize = 0,
accepts: [4]source_namespace.AcceptResult = undefined,
accept_len: usize = 0,
accept_index: usize = 0,
slot_available: bool = true,
start_fails: bool = false,
started_stream: ?u8 = null,
closed_stream: ?u8 = null,
releases: usize = 0,

fn record(capture: *Capture, step: source_namespace.Step) void {
    std.debug.assert(capture.len < capture.steps.len);
    capture.steps[capture.len] = step;
    capture.len += 1;
}

pub fn accept(capture: *Capture) !u8 {
    capture.record(.accept);
    const result = if (capture.accept_index < capture.accept_len)
        capture.accepts[capture.accept_index]
    else
        .listener_closed;
    capture.accept_index += 1;

    return switch (result) {
        .stream => |stream| stream,
        .transient_failure => error.ConnectionAborted,
        .listener_closed => error.SocketNotListening,
        .canceled => error.Canceled,
    };
}

pub fn acquire(capture: *Capture) bool {
    capture.record(.acquire);
    return capture.slot_available;
}

pub fn start(capture: *Capture, _: *source_namespace.Io.Group, stream: u8) !void {
    capture.record(.start);

    if (capture.start_fails) {
        return error.ConcurrencyUnavailable;
    }

    capture.started_stream = stream;
}

pub fn release(capture: *Capture) void {
    capture.record(.release);
    capture.releases += 1;
}

pub fn close(capture: *Capture, stream: u8) void {
    capture.record(.close);
    capture.closed_stream = stream;
}

pub fn cancel(capture: *Capture, _: *source_namespace.Io.Group) void {
    capture.record(.cancel);
}
