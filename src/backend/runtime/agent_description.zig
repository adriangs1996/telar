//! An agent without a title of its own gets one generated from its first
//! prompt by the configured description command, one job at a time.
const agent_status = @import("agent_status.zig");

const std = @import("std");
const RuntimeModel = @import("RuntimeModel.zig");
const AgentResult = @import("../agent/Result.zig");
const Command = @import("../agent/Command.zig");
const DescriptionFinished = @import("../agent/DescriptionFinished.zig");
const description = @import("../agent/description.zig");
const session_checkpoint = @import("session_checkpoint.zig");

/// Starts the next queued description job when the command is configured
/// and no job runs. A job that cannot start is committed as failed.
///
/// ```zig
/// agent_description.start(model);
/// ```
pub fn start(model: *RuntimeModel) void {
    const options = model.agent_description_options orelse return;
    if (model.agent_description_pending) {
        return;
    }

    var job = agent_status.nextDescriptionJob(model) orelse return;
    defer std.crypto.secureZero(u8, &job.query);

    const command: Command = .{ .arguments = options.arguments, .timeout_ms = options.timeout_ms };
    model.select.concurrent(.agent_description, description.generate, .{ model.io, model.gpa, .{ .command = command, .job = job } }) catch {
        commit(model, .{
            .pane = job.pane,
            .session_id = job.session_id,
            .status = .failed,
        });
        return;
    };

    model.agent_description_pending = true;
}

/// Takes one generated description, persists its title and starts the next.
///
/// ```zig
/// agent_description.finish(model, result);
/// ```
pub fn finish(model: *RuntimeModel, result: AgentResult) void {
    std.debug.assert(model.agent_description_pending);
    model.agent_description_pending = false;
    commit(model, result);
    start(model);
}

fn commit(model: *RuntimeModel, result: AgentResult) void {
    const finished: DescriptionFinished = agent_status.finishDescription(model, &result) orelse return;
    _ = model.resources.history.service().setSessionTitle(model.io, .{
        .id = finished.session_id,
        .title = finished.titleSlice(),
        .source = finished.source,
        .state = finished.state,
    });

    if (finished.state == .ready) {
        session_checkpoint.noteChange(model);
    }
}
