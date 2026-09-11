const Capture = @This();
const source_namespace = @import("agent_maintenance.zig");
const agent_mod = @import("../../../agent/root.zig");
const std = @import("std");
steps: [3]source_namespace.Step = undefined,
len: usize = 0,
rearm_failure: bool = false,
now: i64 = 0,
agents: ?*const agent_mod.Tracker = null,
identity: agent_mod.Identity = undefined,
pump_saw_status: ?source_namespace.schema.AgentStatus = null,
pump_called: bool = false,

fn record(capture: *Capture, step: source_namespace.Step) void {
    std.debug.assert(capture.len < capture.steps.len);
    capture.steps[capture.len] = step;
    capture.len += 1;
}

pub fn rearmTick(capture: *Capture) !void {
    capture.record(.rearm_tick);

    if (capture.rearm_failure) {
        return error.SchedulerUnavailable;
    }
}

pub fn nowMs(capture: *Capture) i64 {
    capture.record(.clock);
    return capture.now;
}

pub fn pumpClients(capture: *Capture) void {
    capture.record(.pump_clients);
    capture.pump_called = true;

    const agents = capture.agents orelse return;
    capture.pump_saw_status = agents.projectedStatus(capture.identity.key);
}
