//! Event-driven conversation projection. The provider worker owns JSON and pipes.
const change_review = @import("change_review.zig");
const std = @import("std");
const Pane = @import("../../pane/Pane.zig");
const Changed = @import("AgentThreadChanged.zig");
const RuntimeModel = @import("../RuntimeModel.zig");
const identity = @import("coordinators/agent_identity.zig");
const ManagedState = @import("../../agent/ManagedState.zig");

const agent_hooks = @import("../agent_hooks.zig");
const agent_events = @import("event_dispatcher/agent_events.zig");
/// Waits without polling while the pane retains its lifecycle actor claim.
/// Example: `try select.concurrent(.agent_thread_changed, waitForChange, .{ io, pane });`.
pub fn waitForChange(io: std.Io, pane: *Pane) Changed {
    const session = pane.session.agent.session;
    session.waitForChange(io) catch |err| {
        session.waitStopped(io);
        return .{ .pane = pane.key(), .result = err };
    };
    return .{ .pane = pane.key(), .result = {} };
}

/// Commits the newest bounded snapshot and wakes every subscribed client.
/// Example: `try agent_threads.handle(model, completion);`.
pub fn handle(model: *RuntimeModel, completion: Changed) !bool {
    const pane = model.panes.resolve(completion.pane) orelse return false;
    completion.result catch {
        return true;
    };

    const snapshot = pane.agent_thread.?;
    const previous_id = snapshot.thread_id;
    const previous_len = snapshot.thread_id_len;
    if (pane.session.agent.session.snapshot(model.io, snapshot)) |metadata| {
        const session_changed = !std.mem.eql(u8, previous_id[0..previous_len], snapshot.threadId());
        if (session_changed) {
            model.noteSessionChange();
        }
        if (session_changed or metadata.review_latest_edition_id != pane.session.agent.review_latest_edition_id) {
            change_review.publish(model, .{ .pane_id = pane.id, .pane_generation = pane.generation, .session = snapshot.threadId(), .latest_edition_id = if (session_changed) 0 else metadata.review_latest_edition_id });
            pane.session.agent.review_latest_edition_id = if (session_changed) 0 else metadata.review_latest_edition_id;
        }

        const now = std.Io.Timestamp.now(model.io, .real).toMilliseconds();
        _ = model.agents.observeManaged(identity.fromPane(pane), ManagedState.fromSnapshot(snapshot, now));
        if (metadata.revision != pane.session.agent.metadata_revision) {
            if (metadata.nameSlice()) |name| {
                if (agent_hooks.recordTitle(model, pane.key(), name) == .recorded) {
                    const title = model.agents.durableTitle(pane.key());
                    _ = model.resources.history.service().setSessionTitle(model.io, .{
                        .id = pane.history_session_id,
                        .title = if (title) |*value| value.slice() else "",
                        .source = if (title) |value| value.source else .telar,
                        .state = if (title != null) .ready else .placeholder,
                    });
                    model.noteSessionChange();
                }
            }

            pane.session.agent.metadata_revision = metadata.revision;
        }

        agent_events.scheduleDescription(model);
    }

    try model.select.concurrent(.agent_thread_changed, waitForChange, .{ model.io, pane });
    return false;
}
