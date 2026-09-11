const Capture = @This();
const source_namespace = @import("ingest.zig");
const std = @import("std");
const Read = @import("Read.zig");
steps: [7]source_namespace.Step = undefined,
len: usize = 0,
failure: ?source_namespace.Step = null,
expected_size: ?source_namespace.schema.TerminalSize = null,
observation_saw_released_ingest: bool = false,
observation_saw_expected_size: bool = false,
refresh_saw_expected_size: bool = false,
read_saw_borrow: bool = false,

fn record(capture: *Capture, step: source_namespace.Step) !void {
    std.debug.assert(capture.len < capture.steps.len);
    capture.steps[capture.len] = step;
    capture.len += 1;

    if (capture.failure == step) {
        return error.SchedulerUnavailable;
    }
}

pub fn scheduleObservation(capture: *Capture, pane: *source_namespace.Pane) !void {
    capture.observation_saw_released_ingest = !pane.ingest_pending;
    capture.observation_saw_expected_size = capture.hasExpectedSize(pane);
    try capture.record(.observation);
}

pub fn scheduleMedia(capture: *Capture, _: *source_namespace.Pane) !void {
    try capture.record(.media);
}

pub fn refreshClients(capture: *Capture, pane: *source_namespace.Pane) void {
    capture.refresh_saw_expected_size = capture.hasExpectedSize(pane);
    capture.record(.refresh_clients) catch unreachable;
}

pub fn scheduleResponse(capture: *Capture, _: *source_namespace.Pane) !void {
    try capture.record(.response);
}

pub fn startRead(capture: *Capture, read: Read) !void {
    capture.read_saw_borrow = read.pane.output_pending;
    try capture.record(.read);
}

pub fn collect(capture: *Capture) void {
    capture.record(.collect) catch unreachable;
}

pub fn pumpClients(capture: *Capture) void {
    capture.record(.pump_clients) catch unreachable;
}

fn hasExpectedSize(capture: *const Capture, pane: *const source_namespace.Pane) bool {
    const expected = capture.expected_size orelse return true;
    return std.meta.eql(expected, pane.size);
}
