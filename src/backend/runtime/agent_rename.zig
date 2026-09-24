//! An agent's own session name is read from its session file on a worker,
//! one due file per tick, and outranks a generated title.
const agent_status = @import("agent_status.zig");

const std = @import("std");
const RuntimeModel = @import("RuntimeModel.zig");
const AgentCompletion = @import("../agent/Completion.zig");
const Job = @import("../agent/session_readers/Job.zig");
const readers = @import("../agent/session_readers/session_readers.zig");
const session_checkpoint = @import("session_checkpoint.zig");

const probe_interval_ms: i64 = 1_000;

/// Starts one probe for the stalest due session file, if any.
///
/// ```zig
/// agent_rename.start(model);
/// ```
pub fn start(model: *RuntimeModel) void {
    if (model.session_name_probe_in_flight) {
        return;
    }

    const now_ms = std.Io.Timestamp.now(model.io, .real).toMilliseconds();
    const watch = agent_status.nextSessionFileProbe(model, now_ms, probe_interval_ms) orelse return;

    model.session_name_probe_in_flight = true;
    model.select.concurrent(.session_name, readers.probe, .{Job{ .io = model.io, .watch = watch }}) catch {
        model.session_name_probe_in_flight = false;
        _ = agent_status.finishSessionFileProbe(model, .{ .key = watch.key, .offset = watch.offset }, now_ms);
    };
}

/// Commits one probe result and persists a changed title.
///
/// ```zig
/// agent_rename.finish(model, completion);
/// ```
pub fn finish(model: *RuntimeModel, completion: AgentCompletion) void {
    model.session_name_probe_in_flight = false;
    const now_ms = std.Io.Timestamp.now(model.io, .real).toMilliseconds();

    if (agent_status.finishSessionFileProbe(model, completion, now_ms)) {
        session_checkpoint.noteChange(model);
    }
}
