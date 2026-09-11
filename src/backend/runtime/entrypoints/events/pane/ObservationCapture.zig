const observation_ops = @import("observation.zig");
const ObservationWork = @import("ObservationWork.zig");
const AgentSoundNotificationType = @import("telar-core").AgentSoundNotification;
const std = @import("std");
const Capture = @This();

steps: [5]observation_ops.Step = undefined,
len: usize = 0,
start_failure: bool = false,
started_work: ?ObservationWork = null,
start_saw_borrow: bool = false,
sound: ?AgentSoundNotificationType = null,

fn record(capture: *Capture, step: observation_ops.Step) void {
    std.debug.assert(capture.len < capture.steps.len);
    capture.steps[capture.len] = step;
    capture.len += 1;
}

pub fn start(capture: *Capture, work: ObservationWork) !void {
    capture.record(.observation);
    capture.started_work = work;
    capture.start_saw_borrow = work.pane.history_observer.worker != null and work.pane.actor_count != 0;

    if (capture.start_failure) {
        return error.SchedulerUnavailable;
    }
}

pub fn publishSound(capture: *Capture, notification: AgentSoundNotificationType) void {
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
