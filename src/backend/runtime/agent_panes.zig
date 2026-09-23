//! A managed agent pane projects its provider's conversation: each change
//! commits the newest bounded snapshot; a stopped provider exits the pane.
//! The provider worker owns JSON and pipes.
const change_review = @import("change_review.zig");
const std = @import("std");
const Pane = @import("../pane/Pane.zig");
const Changed = @import("application/AgentThreadChanged.zig");
const RuntimeModel = @import("RuntimeModel.zig");
const identity = @import("application/coordinators/agent_identity.zig");
const ManagedState = @import("../agent/ManagedState.zig");

const agent_hooks = @import("agent_hooks.zig");
const agent_description = @import("agent_description.zig");
const pane_closure = @import("pane_closure.zig");
const session_checkpoint = @import("session_checkpoint.zig");
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

/// Commits the newest bounded snapshot, or exits the pane when its
/// provider stopped, then waits for the next change.
///
/// ```zig
/// try agent_panes.receive(model, completion);
/// ```
pub fn receive(model: *RuntimeModel, completion: Changed) !void {
    const pane = model.panes.resolve(completion.pane) orelse return;
    completion.result catch {
        return pane_closure.finishExit(model, .{ .pane = completion.pane, .result = .{ .exited = 0 } });
    };

    const snapshot = pane.agent_thread.?;
    const previous_id = snapshot.thread_id;
    const previous_len = snapshot.thread_id_len;
    if (pane.session.agent.session.snapshot(model.io, snapshot)) |metadata| {
        const session_changed = !std.mem.eql(u8, previous_id[0..previous_len], snapshot.threadId());
        if (session_changed) {
            session_checkpoint.noteChange(model);
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
                    session_checkpoint.noteChange(model);
                }
            }

            pane.session.agent.metadata_revision = metadata.revision;
        }

        agent_description.start(model);
    }

    try model.select.concurrent(.agent_thread_changed, waitForChange, .{ model.io, pane });
}
