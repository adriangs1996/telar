//! An agent's official lifecycle hooks report its state, session, shell
//! commands and title from inside its pane. Official reports outrank
//! inferred evidence. A hook first has the runtime confirm that its process
//! descends from the pane its environment names; the confirmation holds for
//! that connection. A report that names its agent is accepted only on such a
//! connection and only for the agent the pane runs, so a pane never takes
//! reports from a process that left it or from another agent.
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
const client_connection = @import("client_connection.zig");
const DescentCompletion = @import("events/DescentCompletion.zig");
const ClientKey = @import("../history/ClientKey.zig");
const proclineage = @import("proclineage");

pub const TitleReport = enum { recorded, unchanged, pane_not_found, invalid_title };

const foreign_message = "the report does not come from a process inside the pane";

/// Parents walked from a peer process before its descent is refused: an
/// agent, its launcher and a few shells between the pane's root process and
/// the hook fit well within it.
const max_descent_ancestors = 32;

/// What an observation worker needs to walk one peer's parents.
const DescentWork = struct {
    client: ClientKey,
    request_id: core.RequestId,
    pane: PaneKey,
    root: u32,
    peer: u32,
};

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

    if (try refuseReporter(model, session, report.request_id, .{
        .key = pane.key(),
        .provider = report.provider,
    })) {
        return;
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

    if (try refuseReporter(model, session, report.request_id, .{
        .key = pane.key(),
        .provider = report.provider,
    })) {
        return;
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
    if (try refuseReporter(model, session, report.request_id, .{
        .key = pane.key(),
        .provider = reporter,
    })) {
        return;
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
    const key: PaneKey = .{
        .id = report.pane_id,
        .generation = report.pane_generation,
    };

    if (try refuseReporter(model, session, report.request_id, .{
        .key = key,
        .provider = report.provider,
    })) {
        return;
    }

    switch (recordTitle(model, key, report.provider, report.title)) {
        .recorded => {
            try client_request.complete(session, report.request_id);
            session_checkpoint.noteChange(model);
        },
        .unchanged => try client_request.complete(session, report.request_id),
        .pane_not_found => try client_request.fail(session, report.request_id, .pane_not_found, "pane not found"),
        .invalid_title => try client_request.fail(session, report.request_id, .invalid_request, "invalid session title"),
    }
}

/// Starts confirming that the process at the other end of this connection
/// descends from one exact pane generation. The runtime reads the process
/// from the socket and an observation worker walks its parents, so the
/// sender's word counts for nothing and no request handler inspects a
/// process. `finishDescent` answers.
///
/// ```zig
/// try agent_hooks.receiveDescent(model, session, request);
/// ```
pub fn receiveDescent(model: *RuntimeModel, session: *Session, request: core.VerifyPaneDescent) !void {
    if (session.descent_pending) {
        return client_request.fail(session, request.request_id, .resource_limit, "a descent check is already running");
    }

    const key: PaneKey = .{
        .id = request.pane_id,
        .generation = request.pane_generation,
    };
    const pane = model.panes.resolveConst(key) orelse {
        return client_request.fail(session, request.request_id, .pane_not_found, "pane not found");
    };

    if (pane.exit != null) {
        return client_request.fail(session, request.request_id, .pane_not_found, "pane not found");
    }

    const root = agent_identity.fromPane(pane).process_id;
    const peer = session.connection.peerProcess() catch 0;
    if (root == 0 or peer == 0) {
        return client_request.fail(session, request.request_id, .foreign_process, "the process does not run inside that pane");
    }

    session.hook_pane = null;
    session.descent_pending = true;
    const work: DescentWork = .{
        .client = session.key,
        .request_id = request.request_id,
        .pane = pane.key(),
        .root = root,
        .peer = peer,
    };

    model.select.concurrent(.pane_descent, walkDescent, .{work}) catch {
        session.descent_pending = false;
        return client_request.fail(session, request.request_id, .resource_limit, "no worker for the descent check");
    };
}

/// Binds a confirmed descent to its connection and answers the request. A
/// pane that exited meanwhile, or a connection that is closing, gets none.
///
/// ```zig
/// try agent_hooks.finishDescent(model, completion);
/// ```
pub fn finishDescent(model: *RuntimeModel, completion: DescentCompletion) !void {
    const session = model.clients.resolve(completion.client) orelse return;
    session.descent_pending = false;
    if (session.closing) {
        client_connection.finalize(model, completion.client);
        return;
    }

    if (!session.active()) {
        return;
    }

    const pane = model.panes.resolveConst(completion.pane) orelse {
        return client_request.fail(session, completion.request_id, .pane_not_found, "pane not found");
    };

    if (pane.exit != null) {
        return client_request.fail(session, completion.request_id, .pane_not_found, "pane not found");
    }

    if (!completion.descends) {
        return client_request.fail(session, completion.request_id, .foreign_process, "the process does not run inside that pane");
    }

    session.hook_pane = completion.pane;
    try client_request.complete(session, completion.request_id);
}

// Observation worker: whether the peer is the pane's root process or one of
// its descendants. Bounded, allocation-free system calls.
fn walkDescent(work: DescentWork) DescentCompletion {
    const path = core.enter(.observation);
    defer path.restore();

    var lineage: [max_descent_ancestors]u32 = undefined;
    const ancestors = proclineage.ancestors(work.peer, &lineage);
    return .{
        .client = work.client,
        .request_id = work.request_id,
        .pane = work.pane,
        .descends = work.peer == work.root or std.mem.indexOfScalar(u32, ancestors, work.root) != null,
    };
}

/// The pane and agent a report names.
const Reporter = struct {
    key: PaneKey,
    provider: core.AgentProvider,
};

// A report that names its agent comes from a hook, which must have had this
// connection confirmed as descending from the pane; the pane must run that
// agent too. One that names no agent is the user's own, sent by hand. A
// confirmed hook of another agent may mean the pane's process replaced
// itself since the last probe, so the next observation identifies it again
// and the hook may retry. Returns whether the report was refused.
fn refuseReporter(model: *RuntimeModel, session: *Session, request_id: core.RequestId, reporter: Reporter) !bool {
    if (reporter.provider == .unknown) {
        return false;
    }

    const verified = session.hook_pane orelse return refuseForeign(session, request_id);
    if (verified.id != reporter.key.id or verified.generation != reporter.key.generation) {
        return refuseForeign(session, request_id);
    }

    if (agent_status.acceptsReporter(model, reporter.key, reporter.provider)) {
        return false;
    }

    if (model.panes.resolve(reporter.key)) |pane| {
        pane.agent_recheck_requested = true;
    }

    try client_request.fail(session, request_id, .agent_mismatch, "the pane was last seen running another agent; it is checked again");
    return true;
}

fn refuseForeign(session: *Session, request_id: core.RequestId) !bool {
    try client_request.fail(session, request_id, .foreign_process, foreign_message);
    return true;
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

    const changed = agent_status.reportTitle(model, agent_identity.fromPane(pane), reporter, title) catch return .invalid_title;
    return if (changed) .recorded else .unchanged;
}

test "a process descends from its parent and from itself but not from an unrelated process" {
    const pid: u32 = @intCast(std.c.getpid());
    const parent: u32 = @intCast(std.c.getppid());
    const work: DescentWork = .{
        .client = .{
            .id = 1,
            .generation = 1,
        },
        .request_id = @enumFromInt(1),
        .pane = .{
            .id = @enumFromInt(1),
            .generation = 1,
        },
        .root = parent,
        .peer = pid,
    };

    try std.testing.expect(walkDescent(work).descends);

    var itself = work;
    itself.root = pid;
    try std.testing.expect(walkDescent(itself).descends);

    var unrelated = work;
    unrelated.root = std.math.maxInt(u32);
    try std.testing.expect(!walkDescent(unrelated).descends);
}
