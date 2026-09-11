const output = @import("output.zig");
const std = @import("std");
const PaneType = @import("../../../../pane/Pane.zig");
const OutputIngest = @import("OutputIngest.zig");
const PaneIdType = @import("telar-core").PaneId;
const Capture = @This();

steps: [5]output.Step = undefined,
len: usize = 0,
failure: ?output.Step = null,
outstanding_frame: bool = false,
outstanding_frame_queries: usize = 0,
observation_saw_history: bool = false,
media_saw_output: bool = false,
ingest_saw_borrow: bool = false,
ingest_bytes: []const u8 = "",

fn record(capture: *Capture, step: output.Step) !void {
    std.debug.assert(capture.len < capture.steps.len);
    capture.steps[capture.len] = step;
    capture.len += 1;

    if (capture.failure == step) {
        return error.SchedulerUnavailable;
    }
}

pub fn scheduleObservation(capture: *Capture, pane: *PaneType) !void {
    capture.observation_saw_history = pane.history_observer.hasPending();
    try capture.record(.observation);
}

pub fn scheduleMedia(capture: *Capture, pane: *PaneType) !void {
    capture.media_saw_output = pane.media.hasPending();
    try capture.record(.media);
}

pub fn startIngest(capture: *Capture, ingest: OutputIngest) !void {
    capture.ingest_saw_borrow = ingest.pane.ingest_pending;
    capture.ingest_bytes = ingest.bytes;
    try capture.record(.ingest);
}

pub fn hasOutstandingFrame(capture: *Capture, _: PaneIdType) bool {
    capture.outstanding_frame_queries += 1;
    return capture.outstanding_frame;
}

pub fn collect(capture: *Capture) void {
    capture.record(.collect) catch unreachable;
}

pub fn pumpClients(capture: *Capture) void {
    capture.record(.pump_clients) catch unreachable;
}
