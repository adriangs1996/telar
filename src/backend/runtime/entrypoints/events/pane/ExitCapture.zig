const exit_ops = @import("exit.zig");
const std = @import("std");
const PaneType = @import("../../../../pane/Pane.zig");
const Capture = @This();

steps: [4]exit_ops.Step = undefined,
len: usize = 0,
observation_failure: bool = false,
revoke_saw_exit: bool = false,
observation_saw_history: bool = false,

fn record(capture: *Capture, step: exit_ops.Step) void {
    std.debug.assert(capture.len < capture.steps.len);
    capture.steps[capture.len] = step;
    capture.len += 1;
}

pub fn revokeCredential(capture: *Capture, pane: *PaneType) void {
    capture.record(.revoke_credential);
    capture.revoke_saw_exit = pane.exit != null;
}

pub fn scheduleObservation(capture: *Capture, pane: *PaneType) !void {
    capture.record(.observation);
    capture.observation_saw_history = pane.history_exit_queued and pane.history_observer.hasPending();

    if (capture.observation_failure) {
        return error.SchedulerUnavailable;
    }
}

pub fn collect(capture: *Capture) void {
    capture.record(.collect);
}

pub fn pumpClients(capture: *Capture) void {
    capture.record(.pump_clients);
}
