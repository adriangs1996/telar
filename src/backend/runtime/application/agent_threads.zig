//! Event-driven conversation projection. The provider worker owns JSON and pipes.
const std = @import("std");
const Pane = @import("../../pane/Pane.zig");
const Changed = @import("AgentThreadChanged.zig");
const Application = @import("Application.zig");
const identity = @import("coordinators/agent_identity.zig");
const ManagedState = @import("../../agent/ManagedState.zig");

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
/// Example: `try agent_threads.handle(application, completion);`.
pub fn handle(application: *Application, completion: Changed) !bool {
    const pane = application.model.panes.resolve(completion.pane) orelse return false;
    completion.result catch {
        return true;
    };

    const snapshot = pane.agent_thread.?;
    const previous_id = snapshot.thread_id;
    const previous_len = snapshot.thread_id_len;
    if (pane.session.agent.session.snapshot(application.io, snapshot)) |metadata| {
        if (!std.mem.eql(u8, previous_id[0..previous_len], snapshot.threadId())) {
            application.noteSessionChange();
        }

        const now = std.Io.Timestamp.now(application.io, .real).toMilliseconds();
        _ = application.model.agents.observeManaged(identity.fromPane(pane), ManagedState.fromSnapshot(snapshot, now));
        if (metadata.revision != pane.session.agent.metadata_revision) {
            if (metadata.nameSlice()) |name| {
                var handler: @import("commands/ReportAgentTitleHandler.zig") = .{ .panes = &application.model.panes, .agents = &application.model.agents };
                if (handler.execute(.{ .pane = pane.key(), .title = name }) == .recorded) {
                    const title = application.model.agents.durableTitle(pane.key());
                    _ = application.history_service.setSessionTitle(application.io, .{
                        .id = pane.history_session_id,
                        .title = if (title) |*value| value.slice() else "",
                        .source = if (title) |value| value.source else .telar,
                        .state = if (title != null) .ready else .placeholder,
                    });
                    application.noteSessionChange();
                }
            }

            pane.session.agent.metadata_revision = metadata.revision;
        }

        @import("event_dispatcher/GenericAgentDispatcher.zig").Type(Application).scheduleDescription(application);
        application.pumpAll();
    }

    try application.select.concurrent(.agent_thread_changed, waitForChange, .{ application.io, pane });
    return false;
}
