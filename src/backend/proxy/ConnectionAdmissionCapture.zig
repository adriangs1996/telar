const connection_admission = @import("connection_admission.zig");
const std = @import("std");
const Capture = @This();

steps: [20]connection_admission.Step = undefined,
len: usize = 0,
accepts: [4]connection_admission.AcceptResult = undefined,
accept_len: usize = 0,
accept_index: usize = 0,
slot_available: bool = true,
start_fails: bool = false,
started_stream: ?u8 = null,
closed_stream: ?u8 = null,
releases: usize = 0,

fn record(self: *Capture, step: connection_admission.Step) void {
    std.debug.assert(self.len < self.steps.len);
    self.steps[self.len] = step;
    self.len += 1;
}

pub fn accept(self: *Capture) !u8 {
    self.record(.accept);
    const result = if (self.accept_index < self.accept_len)
        self.accepts[self.accept_index]
    else
        .listener_closed;
    self.accept_index += 1;

    return switch (result) {
        .stream => |stream| stream,
        .transient_failure => error.ConnectionAborted,
        .listener_closed => error.SocketNotListening,
        .canceled => error.Canceled,
    };
}

pub fn acquire(self: *Capture) bool {
    self.record(.acquire);
    return self.slot_available;
}

pub fn start(self: *Capture, _: *std.Io.Group, stream: u8) !void {
    self.record(.start);

    if (self.start_fails) {
        return error.ConcurrencyUnavailable;
    }

    self.started_stream = stream;
}

pub fn release(self: *Capture) void {
    self.record(.release);
    self.releases += 1;
}

pub fn close(self: *Capture, stream: u8) void {
    self.record(.close);
    self.closed_stream = stream;
}

pub fn cancel(self: *Capture, _: *std.Io.Group) void {
    self.record(.cancel);
}
