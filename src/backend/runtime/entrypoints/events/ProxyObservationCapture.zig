const proxy_observation = @import("proxy_observation.zig");
const TrackerType = @import("../../../agent/Tracker.zig");
const PaneKeyType = @import("../../../pane/PaneKey.zig");
const AgentStatusType = @import("telar-core").AgentStatus;
const std = @import("std");
const Capture = @This();

steps: [3]proxy_observation.Step = undefined,
len: usize = 0,
rearm_failure: bool = false,
agents: ?*const TrackerType = null,
pane: PaneKeyType = undefined,
status_at_description_schedule: ?AgentStatusType = null,

fn record(capture: *Capture, step: proxy_observation.Step) void {
    std.debug.assert(capture.len < capture.steps.len);
    capture.steps[capture.len] = step;
    capture.len += 1;
}

pub fn rearmReceive(capture: *Capture) !void {
    capture.record(.rearm_receive);

    if (capture.rearm_failure) {
        return error.SchedulerUnavailable;
    }
}

pub fn scheduleDescription(capture: *Capture) void {
    capture.record(.schedule_description);
    const agents = capture.agents orelse return;
    capture.status_at_description_schedule = agents.projectedStatus(capture.pane);
}

pub fn pumpClients(capture: *Capture) void {
    capture.record(.pump_clients);
}
