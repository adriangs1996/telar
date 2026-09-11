const Capture = @This();
const source_namespace = @import("agent_description.zig");
const State = @import("State.zig");
const Started = @import("Started.zig");
const agent_mod = @import("../../../agent/root.zig");
const std = @import("std");
steps: [8]source_namespace.Step = undefined,
len: usize = 0,
start_failure: bool = false,
expected_query: []const u8 = "",
state: ?*const State = null,
starts: [2]Started = undefined,
start_count: usize = 0,
start_saw_idle: bool = false,
persisted: [2]agent_mod.DescriptionFinished = undefined,
persisted_count: usize = 0,
persist_saw_idle: bool = false,

fn record(capture: *Capture, step: source_namespace.Step) void {
    std.debug.assert(capture.len < capture.steps.len);
    capture.steps[capture.len] = step;
    capture.len += 1;
}

pub fn start(capture: *Capture, _: source_namespace.description.Command, job: source_namespace.description.Job) !void {
    capture.record(.start);
    capture.start_saw_idle = !capture.state.?.isPending();
    std.debug.assert(capture.start_count < capture.starts.len);
    capture.starts[capture.start_count] = .{
        .pane = job.pane,
        .session_id = job.session_id,
        .query_matches = std.mem.eql(u8, capture.expected_query, job.querySlice()),
    };
    capture.start_count += 1;

    if (capture.start_failure) {
        return error.SchedulerUnavailable;
    }
}

pub fn persist(capture: *Capture, finished: agent_mod.DescriptionFinished) void {
    capture.record(.persist);
    capture.persist_saw_idle = !capture.state.?.isPending();
    std.debug.assert(capture.persisted_count < capture.persisted.len);
    capture.persisted[capture.persisted_count] = finished;
    capture.persisted_count += 1;
}

pub fn pumpClients(capture: *Capture) void {
    capture.record(.pump_clients);
}
