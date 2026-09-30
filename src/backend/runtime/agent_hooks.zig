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
const store_support = @import("client/store_support.zig");
const RejectedReporter = @import("../pane/RejectedReporter.zig");
const pane_observation = @import("pane_observation.zig");

pub const TitleReport = enum { recorded, unchanged, pane_not_found, invalid_title };

const foreign_message = "the report does not come from a process inside the pane";

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
    const time = reportTime(model, session);
    const now_ms = time.real_ms;
    const now_ns = time.awake_ns;
    const pane = model.panes.resolveConst(.{ .id = report.pane_id, .generation = report.pane_generation }) orelse {
        return client_request.fail(session, report.request_id, .pane_not_found, "pane not found");
    };

    if (pane.exit != null) {
        return client_request.fail(session, report.request_id, .pane_not_found, "pane not found");
    }

    if (try refuseReporter(model, session, report.request_id, .{
        .key = pane.key(),
        .provider = report.provider,
        .message = .{ .report_agent = report },
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
        .message = .{ .report_agent_progress = report },
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
    const now_ms = reportTime(model, session).real_ms;
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
        .message = .{ .report_agent_command = report },
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
        .message = .{ .report_agent_title = report },
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
    session.hook_lineage_len = completion.ancestor_count;
    @memcpy(session.hook_lineage[0..completion.ancestor_count], completion.lineage());
    try client_request.complete(session, completion.request_id);
}

// Observation worker: whether the peer is the pane's root process or one of
// its descendants. Bounded, allocation-free system calls.
fn walkDescent(work: DescentWork) DescentCompletion {
    const path = core.enter(.observation);
    defer path.restore();

    var completion: DescentCompletion = .{
        .client = work.client,
        .request_id = work.request_id,
        .pane = work.pane,
        .descends = false,
    };
    const ancestors = proclineage.ancestors(work.peer, &completion.ancestors);
    completion.ancestor_count = @intCast(ancestors.len);
    completion.descends = work.peer == work.root or std.mem.indexOfScalar(u32, ancestors, work.root) != null;
    return completion;
}

/// The pane and agent a report names, and the report itself should it wait
/// for the pane's process to be identified again.
const Reporter = struct {
    key: PaneKey,
    provider: core.AgentProvider,
    message: core.ClientMessage,
};

/// How long a parked report waits for its recheck before the pane's
/// current agent answers it. The maintenance tick checks it once a second,
/// so a report waits between two and three seconds at most.
const parked_deadline_ms: i64 = 2_000;

/// A parked report is answered by the first recheck that starts after it
/// arrived: the next one, or the one after a recheck already running,
/// which may have read the process before the report's agent replaced it.
const next_recheck: u32 = 1;
const recheck_after_running: u32 = 2;

// A report that names its agent comes from a hook, which must have had this
// connection confirmed as descending from the pane; the pane must run that
// agent too. One that names no agent is the user's own, sent by hand. A
// confirmed hook of another agent may mean the pane's process replaced
// itself since the last probe: the report is parked until an observation
// that starts after it identifies the process again, then answered. A
// process refused that way before is refused at once while the pane's
// agent is the same. Returns whether the report was refused or parked.
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

    const pane = model.panes.resolve(reporter.key) orelse return refuseForeign(session, request_id);
    if (pane.exit != null) {
        return refuseForeign(session, request_id);
    }

    const rejection = reportingRejection(model, session, pane);
    if (session.answering_parked) {
        // Identified again after this report arrived: the pane still runs
        // another agent, such as the one that ran this hook as a tool. A
        // report answered because its recheck was late proves nothing.
        if (session.parked_rechecked) {
            if (rejection) |value| {
                pane.rejected_reporter = value;
            }
        }

        return refuseForeign(session, request_id);
    }

    if (rejection) |value| {
        if (pane.rejected_reporter) |rejected| {
            if (std.meta.eql(rejected, value)) {
                return refuseForeign(session, request_id);
            }
        }
    }

    session.parked_pane = reporter.key;
    session.parked_recheck = pane.agent_rechecks +% if (pane.agent_recheck_running) recheck_after_running else next_recheck;
    session.parked_at_ms = std.Io.Timestamp.now(model.io, .awake).toMilliseconds();
    session.parked_real_ms = std.Io.Timestamp.now(model.io, .real).toMilliseconds();
    session.parked_awake_ns = @intCast(std.Io.Timestamp.now(model.io, .awake).toNanoseconds());
    pane.agent_recheck_requested = true;
    pane_observation.start(model, pane) catch {
        try client_request.fail(session, request_id, .resource_limit, "the pane's process cannot be identified again now");
        return true;
    };

    model.parked_reports +%= 1;
    session.parked_sequence = model.parked_reports;
    session.parked = reporter.message;
    return true;
}

// Which process a hook reports for, keyed to the pane's agent: the process
// right under that agent in the hook's parent chain, or right under the
// pane's root process when the hook does not descend from the agent. Never
// the agent itself, which may have replaced itself with the reporting
// agent by exec, so a report through it is always identified again.
fn reportingRejection(model: *const RuntimeModel, session: *const Session, pane: *const Pane) ?RejectedReporter {
    const agent = agent_status.agentProcess(model, pane.key()) orelse return null;
    const root = agent_identity.fromPane(pane).process_id;
    const lineage = session.hook_lineage[0..session.hook_lineage_len];

    for (lineage, 0..) |pid, index| {
        if (pid != agent.pid and pid != agent.group and pid != root) {
            continue;
        }

        if (index == 0) {
            return null;
        }

        const process = lineage[index - 1];
        if (process == agent.pid or process == agent.group) {
            return null;
        }

        return .{
            .group = agent.group,
            .agent = agent.pid,
            .process = process,
        };
    }

    return null;
}

/// Answers the reports parked on `key` whose recheck has completed, and
/// those of an agent the pane now runs, whose later reports are no longer
/// parked, in the order they arrived, by dispatching them again. Runs
/// after each observation of the pane.
///
/// ```zig
/// agent_hooks.answerParked(model, pane.key());
/// ```
pub fn answerParked(model: *RuntimeModel, key: PaneKey) void {
    const pane = model.panes.resolveConst(key) orelse return;
    var due: ParkedReports = .{};

    for (model.clients.items) |slot| {
        const session = slot orelse continue;
        if (session.parked == null or session.parked_pane.id != key.id or session.parked_pane.generation != key.generation) {
            continue;
        }

        // Wrapping counters: the answer is due once the count reached it.
        const rechecked = @as(i32, @bitCast(pane.agent_rechecks -% session.parked_recheck)) >= 0;
        if (rechecked or agent_status.acceptsReporter(model, key, parkedProvider(model, session.parked.?))) {
            due.add(session);
        }
    }

    due.answerInOrder(model, true);
}

fn parkedProvider(model: *const RuntimeModel, message: core.ClientMessage) core.AgentProvider {
    return switch (message) {
        .report_agent => |report| report.provider,
        .report_agent_title => |report| report.provider,
        .report_agent_progress => |report| report.provider,
        .report_agent_command => |report| model.resources.agent_manifests.providerNamed(report.provider),
        else => .unknown,
    };
}

/// Answers every parked report whose pane is gone or whose recheck did not
/// complete in time, with the pane's current agent, in the order they
/// arrived. Runs on the maintenance tick.
///
/// ```zig
/// agent_hooks.expireParked(model);
/// ```
pub fn expireParked(model: *RuntimeModel) void {
    const now_ms = std.Io.Timestamp.now(model.io, .awake).toMilliseconds();
    var due: ParkedReports = .{};

    for (model.clients.items) |slot| {
        const session = slot orelse continue;
        if (session.parked == null) {
            continue;
        }

        const pane = model.panes.resolveConst(session.parked_pane);
        const gone = pane == null or pane.?.exit != null;
        if (gone or now_ms - session.parked_at_ms >= parked_deadline_ms) {
            due.add(session);
        }
    }

    due.answerInOrder(model, false);
}

/// Sessions whose parked reports are due, answered by arrival.
const ParkedReports = struct {
    sessions: [store_support.max_clients]*Session = undefined,
    len: usize = 0,

    fn add(self: *ParkedReports, session: *Session) void {
        self.sessions[self.len] = session;
        self.len += 1;
    }

    // `rechecked`: the pane's process was identified again since the
    // reports arrived, so a refusal then is worth remembering.
    fn answerInOrder(self: *ParkedReports, model: *RuntimeModel, rechecked: bool) void {
        const due = self.sessions[0..self.len];
        std.mem.sort(*Session, due, {}, arrivedBefore);

        for (due) |session| {
            session.parked_rechecked = rechecked;
            answer(model, session);
        }
    }

    fn arrivedBefore(_: void, left: *Session, right: *Session) bool {
        return @as(i64, @bitCast(left.parked_sequence -% right.parked_sequence)) < 0;
    }
};

fn answer(model: *RuntimeModel, session: *Session) void {
    const message = session.parked.?;
    session.parked = null;

    if (session.closing) {
        client_connection.finalize(model, session.key);
        return;
    }

    session.answering_parked = true;
    defer session.answering_parked = false;

    client_request.receive(model, session, message) catch {
        client_connection.drop(model, session.key);
        return;
    };

    client_connection.resumeRead(model, session);
}

/// When a report was observed: now, or when it arrived for one answered
/// after a recheck, so it keeps its place among the pane's evidence.
const ReportTime = struct {
    real_ms: i64,
    awake_ns: i64,
};

fn reportTime(model: *const RuntimeModel, session: *const Session) ReportTime {
    if (session.answering_parked) {
        return .{
            .real_ms = session.parked_real_ms,
            .awake_ns = session.parked_awake_ns,
        };
    }

    return .{
        .real_ms = std.Io.Timestamp.now(model.io, .real).toMilliseconds(),
        .awake_ns = @intCast(std.Io.Timestamp.now(model.io, .awake).toNanoseconds()),
    };
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
