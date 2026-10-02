//! How evidence becomes an agent's status: process, screen and lifecycle
//! observations resolve to one pane generation's aggregate, which
//! decides the status; titles, session references and pending resumes
//! follow it; and every change advances the agents revision the snapshot
//! reads.

const RuntimeModel = @import("RuntimeModel.zig");
const Agents = @import("../agent/Agents.zig");
const revisions = @import("../revisions.zig");
const core = @import("telar-core");
const ResumeSession = @import("../agent/ResumeSession.zig");
const ReportObservation = @import("../agent/ReportObservation.zig");
const Identity = @import("../agent/Identity.zig");
const SessionReference = @import("../agent/SessionReference.zig");
const PaneKey = @import("../pane/PaneKey.zig");
const SessionTitle = @import("../agent/SessionTitle.zig");
const ProcessObservation = @import("../agent/ProcessObservation.zig");
const ScreenObservation = @import("../agent/ScreenObservation.zig");
const std = @import("std");
const Job = @import("../agent/Job.zig");
const Result = @import("../agent/Result.zig");
const DescriptionFinished = @import("../agent/DescriptionFinished.zig");
const Watch = @import("../agent/Watch.zig");
const Completion = @import("../agent/Completion.zig");
const Agent = @import("../agent/Agent.zig");
const description = @import("../agent/description.zig");
const ProgressObservation = @import("../agent/ProgressObservation.zig");
const AgentProcess = @import("../agent/AgentProcess.zig");
const Progress = @import("../agent/Progress.zig");
const Watches = @import("../agent/Watches.zig");
const RestoredAgents = @import("../agent/RestoredAgents.zig");
const limit_reached = @import("limit_reached.zig");

pub const AcknowledgeResult = enum {
    unknown_agent,
    unchanged,
    acknowledged,
};

/// Applies one official lifecycle report and its optional session
/// reference, then republishes the projection.
///
/// ```zig
/// _ = agent_status.observeReport(model, .{ .identity = identity, .state = .working, .observed_at_ms = now_ms });
/// ```
pub fn observeReport(model: *RuntimeModel, observation: ReportObservation) bool {
    // A helper's activity is not identity evidence: it renews an agent the
    // runtime already tracks and never registers one.
    if (observation.state == .continuing) {
        const agent = model.agents.find(observation.identity.key) orelse return false;
        if (!agent.applyReport(observation)) {
            return false;
        }

        return reproject(model, agent, observation.observed_at_ms);
    }

    if (observation.session) |session| {
        supersedeRestoredSession(model, observation.identity.key, session);
    }

    const agent = ensure(model, observation.identity) orelse return false;
    agent.claimReporter(observation.provider);
    var changed = false;
    if (observation.session) |session| {
        changed = agent.applySessionReference(session, observation.provider);
    }

    if (observation.session_file.path.len != 0) {
        if (agent.session_reference) |reference| {
            const watched = model.agent_watches.put(.{
                .key = agent.key,
                .session = reference,
                .kind = observation.session_file.kind,
                .path = observation.session_file.path,
            });
            if (!watched and model.agent_watches.full()) {
                limit_reached.report(model, .{
                    .limit = Watches.capacity_limit,
                });
            }
        }
    }

    if (!agent.applyReport(observation)) {
        return changed;
    }

    return reproject(model, agent, observation.observed_at_ms) or changed;
}

/// Applies an agent's reported working tree, plan change and final answer.
/// The aggregate is created when the report precedes other evidence.
///
/// ```zig
/// _ = agent_status.observeProgress(model, .{ .identity = identity, .work_tree = worktree });
/// ```
pub fn observeProgress(model: *RuntimeModel, observation: ProgressObservation) bool {
    const agent = ensure(model, observation.identity) orelse return false;
    agent.claimReporter(observation.provider);
    var changed = false;
    if (observation.work_tree) |work_tree| {
        changed = agent.work_tree != work_tree;
        agent.work_tree = work_tree;
    }

    if (agent.progress.refusesTask(observation.plan)) {
        limit_reached.report(model, .{
            .limit = Progress.tasks_limit,
            .requested = Progress.max_tasks + 1,
        });
    }

    changed = agent.progress.applyPlan(observation.plan) or changed;
    if (observation.final_message.len != 0) {
        changed = agent.progress.setFinalMessage(observation.final_message) or changed;
    }

    if (changed) {
        bumpRevision(model);
    }

    return changed;
}

/// Records the session reference an agent reported for itself. The
/// aggregate is created if the report precedes every other evidence, so a
/// hook that fires before the process is inspected is not lost.
///
/// ```zig
/// if (agent_status.observeSessionReference(model, identity, reference)) noteSessionChange();
/// ```
pub fn observeSessionReference(model: *RuntimeModel, identity: Identity, reference: SessionReference) bool {
    supersedeRestoredSession(model, identity.key, reference);
    const agent = ensure(model, identity) orelse return false;
    const changed = agent.applySessionReference(reference, .unknown);
    return changed;
}

/// Returns durable resume data from an observed process or a pending restore,
/// never from screen or proxy provider guesses.
/// Example: `const session = agent_status.resumeSession(model, key) orelse return;`.
pub fn resumeSession(model: *const RuntimeModel, key: PaneKey) ?ResumeSession {
    if (model.agents.findConst(key)) |agent| {
        if (agent.resumableSession()) |reference| {
            var session = ResumeSession.init(agent.session_provider, reference) catch return null;
            session.in_pane = agent.session_host == .pane;
            return session;
        }
    }

    const pending = model.restored_agents.get(key) orelse return null;
    return pending.session;
}

/// Retains a validated resume until matching process evidence arrives.
/// Example: `_ = agent_status.restoreSession(model, key, session);`.
pub fn restoreSession(model: *RuntimeModel, key: PaneKey, session: ResumeSession) bool {
    return kept(model, model.restored_agents.putSession(key, session));
}

/// Detects duplicate resume attempts during the startup restore pass.
/// Example: `if (agent_status.hasRestoredSession(model, session)) return;`.
pub fn hasRestoredSession(model: *const RuntimeModel, session: ResumeSession) bool {
    return model.restored_agents.containsSession(session);
}

/// Distinguishes a starting resume from an observed foreground agent.
/// Example: `if (agent_status.awaitingResume(model, key)) return;`.
pub fn awaitingResume(model: *const RuntimeModel, key: PaneKey) bool {
    const pending = model.restored_agents.get(key) orelse return false;
    return pending.session != null;
}

/// Whether hooks of `reporter` may report for one exact pane generation: a
/// pane without an agent yet, or one whose agent is `reporter`. A report
/// that names no agent is the user's own and always may.
///
/// ```zig
/// if (!agent_status.acceptsReporter(model, key, .codex)) return refuse();
/// ```
pub fn acceptsReporter(model: *const RuntimeModel, key: PaneKey, reporter: core.AgentProvider) bool {
    const agent = model.agents.findConst(key) orelse return true;
    return agent.acceptsReporter(reporter);
}

/// The agent process evidence names for one exact pane generation: its
/// process group and, when the probe found it, its own process.
///
/// ```zig
/// const process = agent_status.agentProcess(model, key) orelse return;
/// ```
pub fn agentProcess(model: *const RuntimeModel, key: PaneKey) ?AgentProcess {
    const agent = model.agents.findConst(key) orelse return null;
    if (agent.process == null) {
        return null;
    }

    const group = agent.agent_process_group orelse return null;
    return .{
        .group = group,
        .pid = agent.agent_pid orelse group,
    };
}

/// Returns the provider currently projected for one exact pane generation.
///
/// ```zig
/// const provider = agent_status.projectedProvider(model, key);
/// ```
pub fn projectedProvider(model: *const RuntimeModel, key: PaneKey) core.AgentProvider {
    const agent = model.agents.findConst(key) orelse return .unknown;
    return agent.snapshot(0).provider;
}

/// Returns the session reference reported for one exact pane generation.
///
/// ```zig
/// const reference = agent_status.sessionReference(model, key) orelse return;
/// ```
pub fn sessionReference(model: *const RuntimeModel, key: PaneKey) ?SessionReference {
    const agent = model.agents.findConst(key) orelse return null;
    return agent.session_reference;
}

/// Returns the checkpoint-worthy title of one exact pane generation: a
/// ready generated or manual title, never a placeholder.
///
/// ```zig
/// const title = agent_status.durableTitle(model, key) orelse return;
/// ```
pub fn durableTitle(model: *const RuntimeModel, key: PaneKey) ?SessionTitle {
    const agent = model.agents.findConst(key) orelse return null;
    return agent.durableTitle();
}

/// Preserves a title across checkpoints while its resumed process starts.
/// Example: `const title = agent_status.checkpointTitle(model, key);`.
pub fn checkpointTitle(model: *const RuntimeModel, key: PaneKey) ?SessionTitle {
    if (model.agents.findConst(key)) |agent| {
        if (agent.durableTitle()) |title| {
            return title;
        }
    }

    const pending = model.restored_agents.get(key) orelse return null;
    return pending.title;
}

/// Holds a checkpointed title for a restored pane generation until the
/// resumed agent is observed; that aggregate starts with the title ready.
/// Returns `false` when the bounded store is full.
///
/// ```zig
/// _ = agent_status.restoreTitle(model, pane.key(), title);
/// ```
pub fn restoreTitle(model: *RuntimeModel, key: PaneKey, title: SessionTitle) bool {
    if (model.restored_agents.get(key)) |pending| {
        if (pending.session != null) {
            return kept(model, model.restored_agents.putTitle(key, title));
        }
    }

    if (model.agents.find(key)) |agent| {
        agent.restoreTitle(title);
        bumpRevision(model);
        return true;
    }

    return kept(model, model.restored_agents.putTitle(key, title));
}

/// Reports the restored agents' limit when a pane's restored metadata
/// found no slot; `stored` passes through.
fn kept(model: *RuntimeModel, stored: bool) bool {
    if (!stored) {
        limit_reached.report(model, .{
            .limit = RestoredAgents.capacity_limit,
        });
    }

    return stored;
}

/// Marks one exact agent generation as seen and republishes a `done`
/// projection as `ready`. A stale or unknown generation changes nothing.
///
/// ```zig
/// if (agent_status.acknowledge(model, key, now_ms) == .acknowledged) {
///     pumpClients();
/// }
/// ```
pub fn acknowledge(model: *RuntimeModel, key: PaneKey, now_ms: i64) AcknowledgeResult {
    const agent = model.agents.find(key) orelse return .unknown_agent;

    if (!agent.acknowledge()) {
        return .unchanged;
    }

    _ = reproject(model, agent, now_ms);
    return .acknowledged;
}

/// Applies one foreground-process observation to its pane-generation
/// aggregate and republishes the resulting projection.
///
/// ```zig
/// _ = agent_status.observeProcess(model, .{
///     .identity = identity,
///     .provider = .claude,
///     .process_id = 84,
///     .observed_at_ms = 1_000,
/// });
/// ```
pub fn observeProcess(model: *RuntimeModel, observation: ProcessObservation) bool {
    if (observation.provider == .unknown or observation.process_id == 0) {
        return false;
    }

    if (model.restored_agents.get(observation.identity.key)) |pending| {
        if (pending.session) |session| {
            if (session.provider != observation.provider) {
                _ = model.restored_agents.take(observation.identity.key);
                if (model.agents.find(observation.identity.key)) |previous| {
                    previous.retire();
                    _ = removeStored(model, observation.identity.key);
                }
            }
        }
    }

    const agent = ensure(model, observation.identity) orelse return false;
    const had_session = agent.session_reference != null;

    if (!agent.applyProcess(observation)) {
        return false;
    }

    // Another agent's hooks reported before this process was identified:
    // their session is not this agent's, nor is the file they named.
    if (had_session and agent.session_reference == null) {
        _ = model.agent_watches.remove(observation.identity.key);
    }

    if (model.restored_agents.take(observation.identity.key)) |pending| {
        if (pending.session) |session| {
            if (agent.session_reference == null) {
                _ = agent.applySessionReference(session.reference, session.provider);
            }
        }

        if (pending.title) |title| {
            if (agent.durableTitle() == null) {
                agent.restoreTitle(title);
            }
        }
    }

    return reproject(model, agent, observation.observed_at_ms);
}

/// A foreground process-group change is authoritative session exit. Old
/// screen evidence belongs to that process and must not keep its
/// sidebar row alive after the shell regains control.
///
/// ```zig
/// _ = agent_status.clearProcess(model, pane_key);
/// ```
pub fn clearProcess(model: *RuntimeModel, key: PaneKey) bool {
    const agent = model.agents.find(key) orelse return false;

    if (!agent.processExited()) {
        return false;
    }

    return removeStored(model, key);
}

/// Applies one screen observation to an aggregate already established by
/// process or lifecycle evidence. Screen text may refine state,
/// but never creates an agent identity on its own.
///
/// ```zig
/// _ = agent_status.observeScreen(model, .{
///     .identity = identity,
///     .signal = signal,
///     .observed_at_ms = 1_000,
/// });
/// ```
pub fn observeScreen(model: *RuntimeModel, observation: ScreenObservation) bool {
    const agent = model.agents.find(observation.identity.key) orelse return false;

    if (!agent.applyScreen(observation)) {
        return false;
    }

    return reproject(model, agent, observation.observed_at_ms);
}

/// Expires stale evidence across all agents and removes aggregates with no
/// remaining evidence.
///
/// ```zig
/// _ = agent_status.expire(model, now_ms);
/// ```
pub fn expire(model: *RuntimeModel, now_ms: i64) bool {
    var changed = false;
    var iterator = model.agents.iterator();

    while (iterator.next()) |agent| {
        if (agent.expire(now_ms)) {
            const removed = iterator.removeCurrent();
            std.debug.assert(removed);
            bumpRevision(model);
            changed = true;
            continue;
        }

        changed = reproject(model, agent, now_ms) or changed;
    }

    return changed;
}

/// Removes one pane generation and clears its sensitive pending input.
///
/// ```zig
/// _ = agent_status.remove(model, pane_key);
/// ```
pub fn remove(model: *RuntimeModel, key: PaneKey) bool {
    _ = model.restored_agents.take(key);
    const agent = model.agents.find(key) orelse return false;
    agent.retire();
    return removeStored(model, key);
}

/// Copies the current client projections into caller-owned bounded storage.
/// `now_ms` dates each entry's status age without touching the revision.
///
/// ```zig
/// var entries: [max_records]schema.AgentSnapshotEntry = undefined;
/// const snapshot = agent_status.snapshot(&model.agents, &entries, now_ms);
/// ```
pub fn snapshot(agents: *const Agents, entries: *[core.max_agent_snapshot_entries]core.AgentSnapshotEntry, now_ms: i64) []const core.AgentSnapshotEntry {
    var count: usize = 0;
    var iterator = agents.constIterator();

    while (iterator.next()) |agent| {
        entries[count] = agent.snapshot(now_ms);
        count += 1;
    }

    return entries[0..count];
}

/// Returns the last projected status for one exact pane generation.
///
/// ```zig
/// const status = agent_status.projectedStatus(model, pane_key);
/// ```
pub fn projectedStatus(model: *const RuntimeModel, key: PaneKey) ?core.AgentStatus {
    const agent = model.agents.findConst(key) orelse return null;
    return agent.projectedStatus();
}

/// Captures only the first submitted request for an already identified
/// agent. Callers gate this method on explicit description configuration.
///
/// ```zig
/// _ = agent_status.observeInput(model, pane_key, bytes);
/// ```
pub fn observeInput(model: *RuntimeModel, key: PaneKey, bytes: []const u8) bool {
    const agent = model.agents.find(key) orelse return false;
    return agent.observeInput(bytes);
}

/// Starts one bounded job at a time. Invalid captured input deterministically
/// becomes a failed placeholder and is never retried.
///
/// ```zig
/// const job = agent_status.nextDescriptionJob(model);
/// ```
pub fn nextDescriptionJob(model: *RuntimeModel) ?Job {
    var running = model.agents.constIterator();

    while (running.next()) |agent| {
        if (agent.hasRunningDescription()) {
            return null;
        }
    }

    queueWaitingDescriptions(model);
    var queued = model.agents.iterator();

    while (queued.next()) |agent| {
        switch (agent.startDescriptionJob()) {
            .not_queued => {},
            .failed => bumpRevision(model),
            .started => |job| return job,
        }
    }

    return null;
}

/// Queues the descriptions of agents that began work while the queue was
/// full, as far as its free slots go.
fn queueWaitingDescriptions(model: *RuntimeModel) void {
    var pending = pendingDescriptionCount(model);
    var agents = model.agents.iterator();

    while (pending < description.max_pending_jobs) {
        const agent = agents.next() orelse return;
        if (agent.queueWaitingDescription()) {
            pending += 1;
            bumpRevision(model);
        }
    }
}

/// A completion applies only to the exact session which launched it. The
/// returned event owns the aggregate-validated title projection; a manual
/// title makes a concurrent generated result stale by construction.
///
/// ```zig
/// const finished = agent_status.finishDescription(model, &result) orelse return;
/// ```
pub fn finishDescription(model: *RuntimeModel, result: *const Result) ?DescriptionFinished {
    const agent = model.agents.find(result.pane) orelse return null;

    const finished = agent.finishDescription(result) orelse return null;

    bumpRevision(model);
    return finished;
}

/// Replaces generated or pending title state for one existing agent.
///
/// ```zig
/// _ = try agent_status.setManualTitle(model, pane_key, "Review proxy lifecycle");
/// ```
pub fn setManualTitle(model: *RuntimeModel, key: PaneKey, value: []const u8) !bool {
    const agent = model.agents.find(key) orelse return false;
    try agent.setManualTitle(value);
    bumpRevision(model);
    return true;
}

/// Applies the title an agent's hooks reported for one exact pane
/// generation. Like a session reference, the report may precede every
/// other evidence, so the aggregate is created when missing.
///
/// ```zig
/// if (try agent_status.reportTitle(model, identity, .claude, "Fix proxy")) noteSessionChange();
/// ```
pub fn reportTitle(model: *RuntimeModel, identity: Identity, reporter: core.AgentProvider, value: []const u8) !bool {
    const agent = ensure(model, identity) orelse return false;
    agent.claimReporter(reporter);
    if (!try agent.reportTitle(value)) {
        return false;
    }

    bumpRevision(model);
    return true;
}

/// Claims the session file whose probe is most overdue and returns a
/// copy for the worker. A watch whose agent is gone is dropped instead.
///
/// ```zig
/// const watch = agent_status.nextSessionFileProbe(model, now_ms, 1_000) orelse return;
/// ```
pub fn nextSessionFileProbe(model: *RuntimeModel, now_ms: i64, interval_ms: i64) ?Watch {
    while (model.agent_watches.stalest(now_ms, interval_ms)) |watch| {
        if (model.agents.find(watch.key) == null) {
            _ = model.agent_watches.remove(watch.key);
            continue;
        }

        watch.pending = true;
        return watch.*;
    }

    return null;
}

/// Applies one probe result: records progress and hands a name that
/// differs from the last one to the agent like a hook-reported title.
/// Returns whether the title changed.
///
/// ```zig
/// if (agent_status.finishSessionFileProbe(model, completion, now_ms)) noteSessionChange();
/// ```
pub fn finishSessionFileProbe(model: *RuntimeModel, completion: Completion, now_ms: i64) bool {
    const watch = model.agent_watches.find(completion.key) orelse return false;
    watch.pending = false;
    watch.checked_at_ms = now_ms;
    watch.offset = completion.offset;
    if (!completion.has_title or !watch.remember(completion.titleSlice())) {
        return false;
    }

    const agent = model.agents.find(completion.key) orelse {
        _ = model.agent_watches.remove(completion.key);
        return false;
    };
    const changed = agent.reportTitle(completion.titleSlice()) catch return false;
    if (changed) {
        bumpRevision(model);
    }

    return changed;
}

fn ensure(model: *RuntimeModel, identity: Identity) ?*Agent {
    if (model.agents.find(identity.key)) |agent| {
        return agent;
    }

    const agent = model.agents.insert(Agent.init(identity)) orelse {
        if (model.agents.full()) {
            limit_reached.report(model, .{
                .limit = Agents.capacity_limit,
            });
        }

        return null;
    };
    if (model.restored_agents.get(identity.key)) |pending| {
        if (pending.session == null) {
            if (pending.title) |title| {
                agent.restoreTitle(title);
            }

            _ = model.restored_agents.take(identity.key);
        }
    }

    return agent;
}

fn supersedeRestoredSession(model: *RuntimeModel, key: PaneKey, reference: SessionReference) void {
    const pending = model.restored_agents.get(key) orelse return;
    const session = pending.session orelse return;
    if (!std.mem.eql(u8, session.reference.slice(), reference.slice())) {
        _ = model.restored_agents.take(key);
    }
}

fn removeStored(model: *RuntimeModel, key: PaneKey) bool {
    _ = model.agent_watches.remove(key);
    if (!model.agents.remove(key)) {
        return false;
    }

    bumpRevision(model);
    return true;
}

pub fn reproject(model: *RuntimeModel, agent: *Agent, now_ms: i64) bool {
    const previous_sequence = model.agent_sequence;
    const result = agent.reproject(.{
        .sequence = nextSequence(model),
        .now_ms = now_ms,
        .can_queue_description = pendingDescriptionCount(model) < description.max_pending_jobs,
    });

    switch (result) {
        .no_evidence => {
            model.agent_sequence = previous_sequence;
            return false;
        },
        .unchanged => return false,
        .changed => {},
    }

    bumpRevision(model);
    return true;
}

fn pendingDescriptionCount(model: *const RuntimeModel) usize {
    var count: usize = 0;
    var iterator = model.agents.constIterator();

    while (iterator.next()) |agent| {
        if (agent.hasPendingDescription()) {
            count += 1;
        }
    }

    return count;
}

fn nextSequence(model: *RuntimeModel) u64 {
    model.agent_sequence +%= 1;

    if (model.agent_sequence == 0) {
        model.agent_sequence = 1;
    }

    return model.agent_sequence;
}

fn bumpRevision(model: *RuntimeModel) void {
    revisions.advance(&model.agent_revision);
}
