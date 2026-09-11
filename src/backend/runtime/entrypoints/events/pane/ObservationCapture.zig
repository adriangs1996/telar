const Capture = @This();
const source_namespace = @import("observation.zig");
const Work = @import("ObservationWork.zig");
const std = @import("std");
steps: [5]source_namespace.Step = undefined,
len: usize = 0,
start_failure: bool = false,
started_work: ?Work = null,
start_saw_borrow: bool = false,
sound: ?source_namespace.schema.AgentSoundNotification = null,

fn record(capture: *Capture, step: source_namespace.Step) void {
    std.debug.assert(capture.len < capture.steps.len);
    capture.steps[capture.len] = step;
    capture.len += 1;
}

pub fn start(capture: *Capture, work: Work) !void {
    capture.record(.observation);
    capture.started_work = work;
    capture.start_saw_borrow = work.pane.history_observer.worker != null and work.pane.actor_count != 0;

    if (capture.start_failure) {
        return error.SchedulerUnavailable;
    }
}

pub fn publishSound(capture: *Capture, notification: source_namespace.schema.AgentSoundNotification) void {
    capture.record(.sound);
    capture.sound = notification;
}

pub fn scheduleDescription(capture: *Capture) void {
    capture.record(.description);
}

pub fn collect(capture: *Capture) void {
    capture.record(.collect);
}

pub fn pumpClients(capture: *Capture) void {
    capture.record(.pump_clients);
}
