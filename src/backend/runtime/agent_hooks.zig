//! An agent's official lifecycle hooks report its state, session, shell
//! commands and title from inside its pane. Official reports outrank
//! inferred evidence. A hook first proves it runs inside the pane its
//! environment names, and every report names its agent, so a pane never
//! takes reports from a process that left it or from another agent.
const agent_status = @import("agent_status.zig");

const session_checkpoint = @import("session_checkpoint.zig");
const core = @import("telar-core");
const std = @import("std");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const PaneKey = @import("../pane/PaneKey.zig");
const SessionReference = @import("../agent/SessionReference.zig");
const agent_identity = @import("agent_identity.zig");
const agent_sound = @import("agent_sound.zig");
const client_request = @import("client_request.zig");
const sound = @import("../agent/sound.zig");
const Pane = @import("../pane/Pane.zig");
const worktree_lifecycle = @import("worktree_lifecycle.zig");

pub const TitleReport = enum { recorded, unchanged, pane_not_found, foreign_agent, invalid_title };

const foreign_agent_message = "the pane runs another agent";

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
    const recorded = agent_status.observeSessionReference(model, agent_identity.fromPane(pane), reference);
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

    if (!agent_status.acceptsReporter(model, pane.key(), report.provider)) {
        return client_request.fail(session, report.request_id, .foreign_process, foreign_agent_message);
    }

    const reference: ?SessionReference = if (report.session.len == 0)
        null
    else
        SessionReference.init(report.session, now_ms) catch {
            return client_request.fail(session, report.request_id, .invalid_request, "invalid session reference");
        };
    const identity = agent_identity.fromPane(pane);
    const previous = agent_status.projectedStatus(model, identity.key);
    const previous_session = agent_status.sessionReference(model, identity.key);

    const changed = agent_status.observeReport(model, .{
        .identity = identity,
        .provider = report.provider,
        .state = report.state,
        .blocked_reason = report.blocked_reason,
        .event = report.event,
        .observed_at_ms = now_ms,
        .observed_at_ns = now_ns,
        .session = reference,
        .session_file = .{ .kind = report.session_file_kind, .path = report.session_file },
    });
    const current = agent_status.projectedStatus(model, identity.key);
    const current_session = agent_status.sessionReference(model, identity.key);
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

/// Receives what an agent works on: the worktree its working directory
/// resolves to, one plan change and its final answer. A linked worktree
/// nobody registered is tracked as external under the pane's workspace.
///
/// ```zig
/// try agent_hooks.receiveProgress(model, session, report);
/// ```
pub fn receiveProgress(model: *RuntimeModel, session: *Session, report: core.ReportAgentProgress) !void {
    const pane = model.panes.resolveConst(.{ .id = report.pane_id, .generation = report.pane_generation }) orelse {
        return client_request.fail(session, report.request_id, .pane_not_found, "pane not found");
    };

    if (pane.exit != null) {
        return client_request.fail(session, report.request_id, .pane_not_found, "pane not found");
    }

    if (!agent_status.acceptsReporter(model, pane.key(), report.provider)) {
        return client_request.fail(session, report.request_id, .foreign_process, foreign_agent_message);
    }

    const work_tree = try resolveWorkTree(model, pane, report);
    _ = agent_status.observeProgress(model, .{
        .identity = agent_identity.fromPane(pane),
        .provider = report.provider,
        .work_tree = work_tree,
        .plan = .{
            .op = report.plan_op,
            .index = report.plan_index,
            .status = report.plan_status,
            .done = report.plan_done,
            .total = report.plan_total,
            .text = report.plan_text,
        },
        .final_message = report.final_message,
    });
    try client_request.complete(session, report.request_id);
}

/// The worktree a report's directory lies in: a tracked checkout that
/// contains it, else the linked worktree the hook resolved, registered as
/// external, else none. A report without a directory keeps the current one.
fn resolveWorkTree(model: *RuntimeModel, pane: *const Pane, report: core.ReportAgentProgress) !?core.WorktreeId {
    if (report.cwd.len == 0) {
        return null;
    }

    if (model.worktrees.slotContaining(report.cwd)) |slot| {
        return model.worktrees.id[slot];
    }

    if (report.work_tree_path.len == 0) {
        return .invalid;
    }

    const source = workspaceOf(pane) orelse return .invalid;
    // Registration refuses a name it cannot hold whole rather than cutting it.
    const branch = if (report.work_tree_branch.len != 0) report.work_tree_branch else std.fs.path.basename(report.work_tree_path);
    const registered = model.worktrees.register(model.gpa, .{
        .source = model.worktrees.sourceFor(source),
        .created_by = pane.key().id,
        .origin = .external,
        .path = report.work_tree_path,
        .branch = branch,
    }) catch |err| return switch (err) {
        error.OutOfMemory => err,
        else => .invalid,
    };

    if (registered.created) {
        worktree_lifecycle.announce(model);
    }

    return registered.id;
}

fn workspaceOf(pane: *const Pane) ?core.WorkspaceId {
    return switch (pane.location.workspace) {
        .workspace => |id| id,
        .worktree => null,
    };
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

    const reporter = model.resources.agent_manifests.providerNamed(report.provider);
    if (!agent_status.acceptsReporter(model, pane.key(), reporter)) {
        return client_request.fail(session, report.request_id, .foreign_process, foreign_agent_message);
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
    switch (recordTitle(model, .{ .id = report.pane_id, .generation = report.pane_generation }, report.provider, report.title)) {
        .recorded => {
            try client_request.complete(session, report.request_id);
            session_checkpoint.noteChange(model);
        },
        .unchanged => try client_request.complete(session, report.request_id),
        .pane_not_found => try client_request.fail(session, report.request_id, .pane_not_found, "pane not found"),
        .foreign_agent => try client_request.fail(session, report.request_id, .foreign_process, foreign_agent_message),
        .invalid_title => try client_request.fail(session, report.request_id, .invalid_request, "invalid session title"),
    }
}

/// Answers whether the sender descends from one exact pane generation: its
/// parent processes, as it listed them, include the pane's root process.
/// The hook walks its own ancestry, so the runtime inspects no process here.
///
/// ```zig
/// try agent_hooks.receiveDescent(model, session, request);
/// ```
pub fn receiveDescent(model: *RuntimeModel, session: *Session, request: core.VerifyPaneDescent) !void {
    const pane = model.panes.resolveConst(.{ .id = request.pane_id, .generation = request.pane_generation }) orelse {
        return client_request.fail(session, request.request_id, .pane_not_found, "pane not found");
    };

    if (pane.exit != null) {
        return client_request.fail(session, request.request_id, .pane_not_found, "pane not found");
    }

    const root = agent_identity.fromPane(pane).process_id;
    if (root == 0 or std.mem.indexOfScalar(u32, request.slice(), root) == null) {
        return client_request.fail(session, request.request_id, .foreign_process, "the process does not run inside that pane");
    }

    try client_request.complete(session, request.request_id);
}

/// Records a title the hooks of `reporter` sent for one exact pane
/// generation.
///
/// ```zig
/// if (agent_hooks.recordTitle(model, pane.key(), .claude, name) == .recorded) persist();
/// ```
pub fn recordTitle(model: *RuntimeModel, key: PaneKey, reporter: core.AgentProvider, title: []const u8) TitleReport {
    const pane = model.panes.resolveConst(key) orelse return .pane_not_found;
    if (pane.exit != null) {
        return .pane_not_found;
    }

    if (!agent_status.acceptsReporter(model, key, reporter)) {
        return .foreign_agent;
    }

    const changed = agent_status.reportTitle(model, agent_identity.fromPane(pane), reporter, title) catch return .invalid_title;
    return if (changed) .recorded else .unchanged;
}
