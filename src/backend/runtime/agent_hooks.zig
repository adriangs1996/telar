//! An agent's official lifecycle hooks report its state, session, shell
//! commands and title from inside its pane. Official reports outrank
//! inferred evidence.

const session_checkpoint = @import("session_checkpoint.zig");
const core = @import("telar-core");
const std = @import("std");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const PaneKey = @import("../pane/PaneKey.zig");
const SessionReference = @import("../agent/SessionReference.zig");
const agent_identity = @import("application/coordinators/agent_identity.zig");
const agent_sound = @import("agent_sound.zig");
const client_request = @import("client_request.zig");
const sound = @import("../agent/sound.zig");

pub const TitleReport = enum { recorded, unchanged, pane_not_found, invalid_title };

/// Receives the agent's own session reference.
///
/// ```zig
/// try agent_hooks.receiveSession(model, session, report);
/// ```
pub fn receiveSession(model: *RuntimeModel, session: *Session, report: core.ReportAgentSession) !void {
    const now_ms = std.Io.Timestamp.now(model.io, .real).toMilliseconds();
    const pane = model.panes.resolveConst(.{ .id = report.pane_id, .generation = report.pane_generation }) orelse {
        return client_request.fail(session, report.request_id, .pane_not_found, "pane not found");
    };

    if (pane.exit != null) {
        return client_request.fail(session, report.request_id, .pane_not_found, "pane not found");
    }

    const reference = SessionReference.init(report.session, now_ms) catch {
        return client_request.fail(session, report.request_id, .invalid_request, "invalid session reference");
    };
    const recorded = model.agents.observeSessionReference(agent_identity.fromPane(pane), reference);
    try client_request.complete(session, report.request_id);

    if (recorded) {
        session_checkpoint.noteChange(model);
    }
}

/// Receives one lifecycle report and plays the sound its transition earns.
///
/// ```zig
/// try agent_hooks.receive(model, session, report);
/// ```
pub fn receive(model: *RuntimeModel, session: *Session, report: core.ReportAgent) !void {
    const now_ms = std.Io.Timestamp.now(model.io, .real).toMilliseconds();
    const now_ns: i64 = @intCast(std.Io.Timestamp.now(model.io, .awake).toNanoseconds());
    const pane = model.panes.resolveConst(.{ .id = report.pane_id, .generation = report.pane_generation }) orelse {
        return client_request.fail(session, report.request_id, .pane_not_found, "pane not found");
    };

    if (pane.exit != null) {
        return client_request.fail(session, report.request_id, .pane_not_found, "pane not found");
    }

    const reference: ?SessionReference = if (report.session.len == 0)
        null
    else
        SessionReference.init(report.session, now_ms) catch {
            return client_request.fail(session, report.request_id, .invalid_request, "invalid session reference");
        };
    const identity = agent_identity.fromPane(pane);
    const previous = model.agents.projectedStatus(identity.key);
    const previous_session = model.agents.sessionReference(identity.key);

    const changed = model.agents.observeReport(.{
        .identity = identity,
        .state = report.state,
        .blocked_reason = report.blocked_reason,
        .event = report.event,
        .observed_at_ms = now_ms,
        .observed_at_ns = now_ns,
        .session = reference,
        .session_file = .{ .kind = report.session_file_kind, .path = report.session_file },
    });
    const current = model.agents.projectedStatus(identity.key);
    const current_session = model.agents.sessionReference(identity.key);
    try client_request.complete(session, report.request_id);

    const session_recorded = if (current_session) |recorded|
        if (previous_session) |before| !std.mem.eql(u8, recorded.slice(), before.slice()) else true
    else
        false;
    if (session_recorded) {
        session_checkpoint.noteChange(model);
    }

    if (!changed) {
        return;
    }

    const transition = sound.soundForTransition(previous, current) orelse return;
    agent_sound.publish(model, .{
        .pane_id = report.pane_id,
        .pane_generation = report.pane_generation,
        .sound = transition,
    });
}

/// Receives one shell command the agent ran, for command history.
///
/// ```zig
/// try agent_hooks.receiveCommand(model, session, report);
/// ```
pub fn receiveCommand(model: *RuntimeModel, session: *Session, report: core.ReportAgentCommand) !void {
    const now_ms = std.Io.Timestamp.now(model.io, .real).toMilliseconds();
    const pane = model.panes.resolve(.{ .id = report.pane_id, .generation = report.pane_generation }) orelse {
        return client_request.fail(session, report.request_id, .pane_not_found, "pane not found");
    };

    if (pane.exit != null) {
        return client_request.fail(session, report.request_id, .pane_not_found, "pane not found");
    }

    const queued = pane.recordAgentCommand(.{
        .command = .{
            .bytes = report.command,
            .cwd = report.cwd,
            .started_at_ms = now_ms,
            .duration_ns = 0,
            .exit_code = report.exit_code,
            .status = .completed,
            .truncated = false,
        },
        .provider = report.provider,
        .tool_call_id = report.tool_call_id,
        .origin = .hook,
        .phase = report.phase,
    });
    if (!queued) {
        return client_request.fail(session, report.request_id, .resource_limit, "history queue full");
    }

    try client_request.complete(session, report.request_id);
}

/// Receives the name the agent's own session carries.
///
/// ```zig
/// try agent_hooks.receiveTitle(model, session, report);
/// ```
pub fn receiveTitle(model: *RuntimeModel, session: *Session, report: core.ReportAgentTitle) !void {
    switch (recordTitle(model, .{ .id = report.pane_id, .generation = report.pane_generation }, report.title)) {
        .recorded => {
            try client_request.complete(session, report.request_id);
            session_checkpoint.noteChange(model);
        },
        .unchanged => try client_request.complete(session, report.request_id),
        .pane_not_found => try client_request.fail(session, report.request_id, .pane_not_found, "pane not found"),
        .invalid_title => try client_request.fail(session, report.request_id, .invalid_request, "invalid session title"),
    }
}

/// Records an agent-reported title for one exact pane generation.
///
/// ```zig
/// if (agent_hooks.recordTitle(model, pane.key(), name) == .recorded) persist();
/// ```
pub fn recordTitle(model: *RuntimeModel, key: PaneKey, title: []const u8) TitleReport {
    const pane = model.panes.resolveConst(key) orelse return .pane_not_found;
    if (pane.exit != null) {
        return .pane_not_found;
    }

    const changed = model.agents.reportTitle(agent_identity.fromPane(pane), title) catch return .invalid_title;
    return if (changed) .recorded else .unchanged;
}
