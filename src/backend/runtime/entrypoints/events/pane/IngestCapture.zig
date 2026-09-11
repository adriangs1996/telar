const ingest = @import("ingest.zig");
const TerminalSizeType = @import("telar-core").TerminalSize;
const std = @import("std");
const PaneType = @import("../../../../pane/Pane.zig");
const Read = @import("Read.zig");
const Capture = @This();

steps: [7]ingest.Step = undefined,
len: usize = 0,
failure: ?ingest.Step = null,
expected_size: ?TerminalSizeType = null,
observation_saw_released_ingest: bool = false,
observation_saw_expected_size: bool = false,
refresh_saw_expected_size: bool = false,
read_saw_borrow: bool = false,

fn record(capture: *Capture, step: ingest.Step) !void {
    std.debug.assert(capture.len < capture.steps.len);
    capture.steps[capture.len] = step;
    capture.len += 1;

    if (capture.failure == step) {
        return error.SchedulerUnavailable;
    }
}

pub fn scheduleObservation(capture: *Capture, pane: *PaneType) !void {
    capture.observation_saw_released_ingest = !pane.ingest_pending;
    capture.observation_saw_expected_size = capture.hasExpectedSize(pane);
    try capture.record(.observation);
}

pub fn scheduleMedia(capture: *Capture, _: *PaneType) !void {
    try capture.record(.media);
}

pub fn refreshClients(capture: *Capture, pane: *PaneType) void {
    capture.refresh_saw_expected_size = capture.hasExpectedSize(pane);
    capture.record(.refresh_clients) catch unreachable;
}

pub fn scheduleResponse(capture: *Capture, _: *PaneType) !void {
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

fn hasExpectedSize(capture: *const Capture, pane: *const PaneType) bool {
    const expected = capture.expected_size orelse return true;
    return std.meta.eql(expected, pane.size);
}
