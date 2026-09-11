const Capture = @This();
const source_namespace = @import("proxy_observation.zig");
const agent_mod = @import("../../../agent/root.zig");
const pane_mod = @import("../../../pane/root.zig");
const core = @import("telar-core");
const std = @import("std");
steps: [3]source_namespace.Step = undefined,
len: usize = 0,
rearm_failure: bool = false,
agents: ?*const agent_mod.Tracker = null,
pane: pane_mod.PaneKey = undefined,
status_at_description_schedule: ?core.schema.AgentStatus = null,

fn record(capture: *Capture, step: source_namespace.Step) void {
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
