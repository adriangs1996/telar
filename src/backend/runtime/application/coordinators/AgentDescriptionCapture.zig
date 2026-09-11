const agent_description = @import("agent_description.zig");
const State = @import("State.zig");
const Started = @import("Started.zig");
const DescriptionFinishedType = @import("../../../agent/DescriptionFinished.zig");
const std = @import("std");
const CommandType = @import("../../../agent/Command.zig");
const JobType = @import("../../../agent/Job.zig");
const Capture = @This();

steps: [8]agent_description.Step = undefined,
len: usize = 0,
start_failure: bool = false,
expected_query: []const u8 = "",
state: ?*const State = null,
starts: [2]Started = undefined,
start_count: usize = 0,
start_saw_idle: bool = false,
persisted: [2]DescriptionFinishedType = undefined,
persisted_count: usize = 0,
persist_saw_idle: bool = false,

fn record(capture: *Capture, step: agent_description.Step) void {
    std.debug.assert(capture.len < capture.steps.len);
    capture.steps[capture.len] = step;
    capture.len += 1;
}

pub fn start(capture: *Capture, _: CommandType, job: JobType) !void {
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

pub fn persist(capture: *Capture, finished: DescriptionFinishedType) void {
    capture.record(.persist);
    capture.persist_saw_idle = !capture.state.?.isPending();
    std.debug.assert(capture.persisted_count < capture.persisted.len);
    capture.persisted[capture.persisted_count] = finished;
    capture.persisted_count += 1;
}

pub fn pumpClients(capture: *Capture) void {
    capture.record(.pump_clients);
}
