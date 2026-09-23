const revisions = @import("../revisions.zig");
const core = @import("telar-core");
const Repository = @import("Repository.zig");
const RestoredAgents = @import("RestoredAgents.zig");
const ResumeSession = @import("ResumeSession.zig");
const Watches = @import("Watches.zig");
const ReportObservation = @import("ReportObservation.zig");
const Identity = @import("Identity.zig");
const SessionReference = @import("SessionReference.zig");
const PaneKey = @import("../pane/PaneKey.zig");
const SessionTitle = @import("SessionTitle.zig");
const tracker_support = @import("tracker_support.zig");
const ProcessObservation = @import("ProcessObservation.zig");
const ProxyObservation = @import("ProxyObservation.zig");
const ScreenObservation = @import("ScreenObservation.zig");
const std = @import("std");
const Job = @import("Job.zig");
const Result = @import("Result.zig");
const DescriptionFinished = @import("DescriptionFinished.zig");
const Watch = @import("Watch.zig");
const Completion = @import("Completion.zig");
const Agent = @import("Agent.zig");
const description = @import("description.zig");
const Tracker = @This();

repository: Repository = .{},
restored_agents: RestoredAgents = .{},
watches: Watches = .{},
revision: u64 = 1,
/// Advances whenever an agent's session reference changes; the session
/// reference names the change-review owner, which the projection
/// revision does not cover.
session_revision: u64 = 0,
sequence: u64 = 0,

/// Applies one official lifecycle report and its optional session
/// reference, then republishes the projection.
///
/// ```zig
/// _ = tracker.observeReport(.{ .identity = identity, .state = .working, .observed_at_ms = now_ms });
/// ```
pub fn observeReport(self: *Tracker, observation: ReportObservation) bool {
    if (observation.session) |session| {
        self.supersedeRestoredSession(observation.identity.key, session);
    }

    const agent = self.ensure(observation.identity) orelse return false;
    var changed = false;
    if (observation.session) |session| {
        changed = agent.applySessionReference(session);
        self.session_revision +%= @intFromBool(changed);
    }

    if (observation.session_file.path.len != 0) {
        if (agent.session_reference) |reference| {
            _ = self.watches.put(.{
                .key = agent.key,
                .session = reference,
                .kind = observation.session_file.kind,
                .path = observation.session_file.path,
            });
        }
    }

    if (!agent.applyReport(observation)) {
        return changed;
    }

    return self.reproject(agent, observation.observed_at_ms) or changed;
}

/// Records the session reference an agent reported for itself. The
/// aggregate is created if the report precedes every other evidence, so a
/// hook that fires before the process is inspected is not lost.
///
/// ```zig
/// if (tracker.observeSessionReference(identity, reference)) noteSessionChange();
/// ```
pub fn observeSessionReference(self: *Tracker, identity: Identity, reference: SessionReference) bool {
    self.supersedeRestoredSession(identity.key, reference);
    const agent = self.ensure(identity) orelse return false;
    const changed = agent.applySessionReference(reference);
    self.session_revision +%= @intFromBool(changed);
    return changed;
}

/// Returns durable resume data from an observed process or a pending restore,
/// never from screen or proxy provider guesses.
/// Example: `const session = tracker.resumeSession(key) orelse return;`.
pub fn resumeSession(self: *const Tracker, key: PaneKey) ?ResumeSession {
    if (self.repository.findConst(key)) |agent| {
        if (agent.session_reference) |reference| {
            if (agent.process) |process| {
                return ResumeSession.init(process.provider, reference) catch null;
            }
        }
    }

    const pending = self.restored_agents.get(key) orelse return null;
    return pending.session;
}

/// Retains a validated resume until matching process evidence arrives.
/// Example: `_ = tracker.restoreSession(key, session);`.
pub fn restoreSession(self: *Tracker, key: PaneKey, session: ResumeSession) bool {
    return self.restored_agents.putSession(key, session);
}

/// Detects duplicate resume attempts during the startup restore pass.
/// Example: `if (tracker.hasRestoredSession(session)) return;`.
pub fn hasRestoredSession(self: *const Tracker, session: ResumeSession) bool {
    return self.restored_agents.containsSession(session);
}

/// Distinguishes a starting resume from an observed foreground agent.
/// Example: `if (tracker.awaitingResume(key)) return;`.
pub fn awaitingResume(self: *const Tracker, key: PaneKey) bool {
    const pending = self.restored_agents.get(key) orelse return false;
    return pending.session != null;
}

/// Returns the provider currently projected for one exact pane generation.
///
/// ```zig
/// const provider = tracker.projectedProvider(key);
/// ```
pub fn projectedProvider(self: *const Tracker, key: PaneKey) core.AgentProvider {
    const agent = self.repository.findConst(key) orelse return .unknown;
    return agent.snapshot(0).provider;
}

/// Returns the session reference reported for one exact pane generation.
///
/// ```zig
/// const reference = tracker.sessionReference(key) orelse return;
/// ```
pub fn sessionReference(self: *const Tracker, key: PaneKey) ?SessionReference {
    const agent = self.repository.findConst(key) orelse return null;
    return agent.session_reference;
}

/// Returns the checkpoint-worthy title of one exact pane generation: a
/// ready generated or manual title, never a placeholder.
///
/// ```zig
/// const title = tracker.durableTitle(key) orelse return;
/// ```
pub fn durableTitle(self: *const Tracker, key: PaneKey) ?SessionTitle {
    const agent = self.repository.findConst(key) orelse return null;
    return agent.durableTitle();
}

/// Preserves a title across checkpoints while its resumed process starts.
/// Example: `const title = tracker.checkpointTitle(key);`.
pub fn checkpointTitle(self: *const Tracker, key: PaneKey) ?SessionTitle {
    if (self.repository.findConst(key)) |agent| {
        if (agent.durableTitle()) |title| {
            return title;
        }
    }

    const pending = self.restored_agents.get(key) orelse return null;
    return pending.title;
}

/// Holds a checkpointed title for a restored pane generation until the
/// resumed agent is observed; that aggregate starts with the title ready.
/// Returns `false` when the bounded store is full.
///
/// ```zig
/// _ = tracker.restoreTitle(pane.key(), title);
/// ```
pub fn restoreTitle(self: *Tracker, key: PaneKey, title: SessionTitle) bool {
    if (self.restored_agents.get(key)) |pending| {
        if (pending.session != null) {
            return self.restored_agents.putTitle(key, title);
        }
    }

    if (self.repository.find(key)) |agent| {
        agent.restoreTitle(title);
        self.bumpRevision();
        return true;
    }

    return self.restored_agents.putTitle(key, title);
}

/// Marks one exact agent generation as seen and republishes a `done`
/// projection as `ready`. A stale or unknown generation changes nothing.
///
/// ```zig
/// if (tracker.acknowledge(key, now_ms) == .acknowledged) {
///     pumpClients();
/// }
/// ```
pub fn acknowledge(self: *Tracker, key: PaneKey, now_ms: i64) tracker_support.AcknowledgeResult {
    const agent = self.repository.find(key) orelse return .unknown_agent;

    if (!agent.acknowledge()) {
        return .unchanged;
    }

    _ = self.reproject(agent, now_ms);
    return .acknowledged;
}

/// Applies one foreground-process observation to its pane-generation
/// aggregate and republishes the resulting projection.
///
/// ```zig
/// _ = tracker.observeProcess(.{
///     .identity = identity,
///     .provider = .claude,
///     .process_id = 84,
///     .observed_at_ms = 1_000,
/// });
/// ```
pub fn observeProcess(self: *Tracker, observation: ProcessObservation) bool {
    if (observation.provider == .unknown or observation.process_id == 0) {
        return false;
    }

    if (self.restored_agents.get(observation.identity.key)) |pending| {
        if (pending.session) |session| {
            if (session.provider != observation.provider) {
                _ = self.restored_agents.take(observation.identity.key);
                if (self.repository.find(observation.identity.key)) |previous| {
                    previous.retire();
                    _ = self.removeStored(observation.identity.key);
                }
            }
        }
    }

    const agent = self.ensure(observation.identity) orelse return false;

    if (!agent.applyProcess(observation)) {
        return false;
    }

    if (self.restored_agents.take(observation.identity.key)) |pending| {
        if (pending.session) |session| {
            if (agent.session_reference == null) {
                self.session_revision +%= @intFromBool(agent.applySessionReference(session.reference));
            }
        }

        if (pending.title) |title| {
            if (agent.durableTitle() == null) {
                agent.restoreTitle(title);
            }
        }
    }

    return self.reproject(agent, observation.observed_at_ms);
}

/// A foreground process-group change is authoritative session exit. Old
/// proxy and screen evidence belongs to that process and must not keep its
/// sidebar row alive after the shell regains control.
///
/// ```zig
/// _ = tracker.clearProcess(pane_key);
/// ```
pub fn clearProcess(self: *Tracker, key: PaneKey) bool {
    const agent = self.repository.find(key) orelse return false;

    if (!agent.processExited()) {
        return false;
    }

    return self.removeStored(key);
}

/// Applies one proxy lifecycle observation to the agent identified by
/// `observation.identity`.
///
/// `request_started` opens a bounded tracked exchange and may create the
/// agent. Activity, provider turn completion, transport completion, and failure
/// observations require a matching exchange; unmatched observations cannot
/// create or settle agent state. Callers must filter auxiliary requests
/// before calling this method.
///
/// An accepted observation refreshes proxy evidence and recomputes the
/// public agent projection. A successful HTTP response remains `working`
/// because transport completion does not prove that the agent turn ended.
/// The return value is `true` only when the projected snapshot or title
/// state changed. This method does not parse HTTP bodies or provider events.
///
/// ```zig
/// fn observeHttp11Exchange(tracker: *Tracker, identity: Identity) void {
///     const exchange: ProxyExchange = .{
///         .protocol = .http11,
///         .connection_id = 17,
///         .stream_id = 0,
///     };
///     _ = tracker.observeProxy(.{
///         .identity = identity,
///         .provider = .claude,
///         .phase = .request_started,
///         .exchange = exchange,
///         .observed_at_ms = 1_000,
///     });
///     _ = tracker.observeProxy(.{
///         .identity = identity,
///         .provider = .claude,
///         .phase = .response_activity,
///         .exchange = exchange,
///         .observed_at_ms = 1_100,
///     });
///     _ = tracker.observeProxy(.{
///         .identity = identity,
///         .provider = .claude,
///         .phase = .response_finished,
///         .exchange = exchange,
///         .observed_at_ms = 1_200,
///     });
/// }
/// ```
pub fn observeProxy(self: *Tracker, observation: ProxyObservation) bool {
    if (observation.dialect == .unknown) {
        return false;
    }

    const agent = self.resolveProxyAgent(&observation) orelse return false;
    if (!agent.applyProxy(observation)) {
        return false;
    }

    return self.reproject(agent, observation.observed_at_ms);
}

/// Applies one screen observation to an aggregate already established by
/// process, proxy, or lifecycle evidence. Screen text may refine state,
/// but never creates an agent identity on its own.
///
/// ```zig
/// _ = tracker.observeScreen(.{
///     .identity = identity,
///     .signal = signal,
///     .observed_at_ms = 1_000,
/// });
/// ```
pub fn observeScreen(self: *Tracker, observation: ScreenObservation) bool {
    const agent = self.repository.find(observation.identity.key) orelse return false;

    if (!agent.applyScreen(observation)) {
        return false;
    }

    return self.reproject(agent, observation.observed_at_ms);
}

/// Expires stale evidence across all agents and removes aggregates with no
/// remaining evidence.
///
/// ```zig
/// _ = tracker.expire(now_ms);
/// ```
pub fn expire(self: *Tracker, now_ms: i64) bool {
    var changed = false;
    var iterator = self.repository.iterator();

    while (iterator.next()) |agent| {
        if (agent.expire(now_ms)) {
            const removed = iterator.removeCurrent();
            std.debug.assert(removed);
            self.bumpRevision();
            changed = true;
            continue;
        }

        changed = self.reproject(agent, now_ms) or changed;
    }

    return changed;
}

/// Removes one pane generation and clears its sensitive pending input.
///
/// ```zig
/// _ = tracker.remove(pane_key);
/// ```
pub fn remove(self: *Tracker, key: PaneKey) bool {
    _ = self.restored_agents.take(key);
    const agent = self.repository.find(key) orelse return false;
    agent.retire();
    return self.removeStored(key);
}

/// Copies the current client projections into caller-owned bounded storage.
/// `now_ms` dates each entry's status age without touching the revision.
///
/// ```zig
/// var entries: [max_records]schema.AgentSnapshotEntry = undefined;
/// const snapshot = tracker.snapshot(&entries, now_ms);
/// ```
pub fn snapshot(self: *const Tracker, entries: *[core.max_agent_snapshot_entries]core.AgentSnapshotEntry, now_ms: i64) []const core.AgentSnapshotEntry {
    var count: usize = 0;
    var iterator = self.repository.constIterator();

    while (iterator.next()) |agent| {
        entries[count] = agent.snapshot(now_ms);
        count += 1;
    }

    return entries[0..count];
}

/// Returns the last projected status for one exact pane generation.
///
/// ```zig
/// const status = tracker.projectedStatus(pane_key);
/// ```
pub fn projectedStatus(self: *const Tracker, key: PaneKey) ?core.AgentStatus {
    const agent = self.repository.findConst(key) orelse return null;
    return agent.projectedStatus();
}

/// Captures only the first submitted request for an already identified
/// agent. Callers gate this method on explicit description configuration.
///
/// ```zig
/// _ = tracker.observeInput(pane_key, bytes);
/// ```
pub fn observeInput(self: *Tracker, key: PaneKey, bytes: []const u8) bool {
    const agent = self.repository.find(key) orelse return false;
    return agent.observeInput(bytes);
}

/// Captures the first accepted managed prompt when the caller opted into title generation.
/// Example: `_ = tracker.observeSubmittedPrompt(identity, "Fix tests\nKeep behavior");`.
pub fn observeSubmittedPrompt(self: *Tracker, identity: Identity, text: []const u8) bool {
    const agent = self.ensure(identity) orelse return false;
    if (!agent.observeSubmittedPrompt(text, self.pendingDescriptionCount() < description.max_pending_jobs)) {
        return false;
    }

    self.bumpRevision();
    return true;
}

/// Starts one bounded job at a time. Invalid captured input deterministically
/// becomes a failed placeholder and is never retried.
///
/// ```zig
/// const job = tracker.nextDescriptionJob();
/// ```
pub fn nextDescriptionJob(self: *Tracker) ?Job {
    var running = self.repository.constIterator();

    while (running.next()) |agent| {
        if (agent.hasRunningDescription()) {
            return null;
        }
    }

    var queued = self.repository.iterator();

    while (queued.next()) |agent| {
        switch (agent.startDescriptionJob()) {
            .not_queued => {},
            .failed => self.bumpRevision(),
            .started => |job| return job,
        }
    }

    return null;
}

/// A completion applies only to the exact session which launched it. The
/// returned event owns the aggregate-validated title projection; a manual
/// title makes a concurrent generated result stale by construction.
///
/// ```zig
/// const finished = tracker.finishDescription(&result) orelse return;
/// ```
pub fn finishDescription(self: *Tracker, result: *const Result) ?DescriptionFinished {
    const agent = self.repository.find(result.pane) orelse return null;

    const finished = agent.finishDescription(result) orelse return null;

    self.bumpRevision();
    return finished;
}

/// Replaces generated or pending title state for one existing agent.
///
/// ```zig
/// _ = try tracker.setManualTitle(pane_key, "Review proxy lifecycle");
/// ```
pub fn setManualTitle(self: *Tracker, key: PaneKey, value: []const u8) !bool {
    const agent = self.repository.find(key) orelse return false;
    try agent.setManualTitle(value);
    self.bumpRevision();
    return true;
}

/// Applies the title an agent's hooks reported for one exact pane
/// generation. Like a session reference, the report may precede every
/// other evidence, so the aggregate is created when missing.
///
/// ```zig
/// if (try tracker.reportTitle(identity, "Fix proxy")) noteSessionChange();
/// ```
pub fn reportTitle(self: *Tracker, identity: Identity, value: []const u8) !bool {
    const agent = self.ensure(identity) orelse return false;
    if (!try agent.reportTitle(value)) {
        return false;
    }

    self.bumpRevision();
    return true;
}

/// Claims the session file whose probe is most overdue and returns a
/// copy for the worker. A watch whose agent is gone is dropped instead.
///
/// ```zig
/// const watch = tracker.nextSessionFileProbe(now_ms, 1_000) orelse return;
/// ```
pub fn nextSessionFileProbe(self: *Tracker, now_ms: i64, interval_ms: i64) ?Watch {
    while (self.watches.stalest(now_ms, interval_ms)) |watch| {
        if (self.repository.find(watch.key) == null) {
            _ = self.watches.remove(watch.key);
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
/// if (tracker.finishSessionFileProbe(completion, now_ms)) noteSessionChange();
/// ```
pub fn finishSessionFileProbe(self: *Tracker, completion: Completion, now_ms: i64) bool {
    const watch = self.watches.find(completion.key) orelse return false;
    watch.pending = false;
    watch.checked_at_ms = now_ms;
    watch.offset = completion.offset;
    if (!completion.has_title or !watch.remember(completion.titleSlice())) {
        return false;
    }

    const agent = self.repository.find(completion.key) orelse {
        _ = self.watches.remove(completion.key);
        return false;
    };
    const changed = agent.reportTitle(completion.titleSlice()) catch return false;
    if (changed) {
        self.bumpRevision();
    }

    return changed;
}

fn resolveProxyAgent(self: *Tracker, observation: *const ProxyObservation) ?*Agent {
    return switch (observation.phase) {
        .request_started => self.ensure(observation.identity),
        .response_activity, .provider_turn_completed, .response_finished, .request_failed => self.repository.find(observation.identity.key),
    };
}

fn ensure(self: *Tracker, identity: Identity) ?*Agent {
    if (self.repository.find(identity.key)) |agent| {
        return agent;
    }

    const agent = self.repository.insert(Agent.init(identity)) orelse return null;
    if (self.restored_agents.get(identity.key)) |pending| {
        if (pending.session == null) {
            if (pending.title) |title| {
                agent.restoreTitle(title);
            }

            _ = self.restored_agents.take(identity.key);
        }
    }

    return agent;
}

fn supersedeRestoredSession(self: *Tracker, key: PaneKey, reference: SessionReference) void {
    const pending = self.restored_agents.get(key) orelse return;
    const session = pending.session orelse return;
    if (!std.mem.eql(u8, session.reference.slice(), reference.slice())) {
        _ = self.restored_agents.take(key);
    }
}

fn removeStored(self: *Tracker, key: PaneKey) bool {
    _ = self.watches.remove(key);
    if (!self.repository.remove(key)) {
        return false;
    }

    self.bumpRevision();
    return true;
}

pub fn reproject(self: *Tracker, agent: *Agent, now_ms: i64) bool {
    const previous_sequence = self.sequence;
    const result = agent.reproject(.{
        .sequence = self.nextSequence(),
        .now_ms = now_ms,
        .can_queue_description = self.pendingDescriptionCount() < description.max_pending_jobs,
    });

    switch (result) {
        .no_evidence => {
            self.sequence = previous_sequence;
            return false;
        },
        .unchanged => return false,
        .changed => {},
    }

    self.bumpRevision();
    return true;
}

fn pendingDescriptionCount(self: *const Tracker) usize {
    var count: usize = 0;
    var iterator = self.repository.constIterator();

    while (iterator.next()) |agent| {
        if (agent.hasPendingDescription()) {
            count += 1;
        }
    }

    return count;
}

fn nextSequence(self: *Tracker) u64 {
    self.sequence +%= 1;

    if (self.sequence == 0) {
        self.sequence = 1;
    }

    return self.sequence;
}

fn bumpRevision(self: *Tracker) void {
    revisions.advance(&self.revision);
}

/// Updates the lifecycle projection for one runtime-owned provider session.
/// Example: `_ = tracker.observeManaged(identity, state);`.
pub fn observeManaged(self: *Tracker, identity: Identity, state: @import("ManagedState.zig")) bool {
    const agent = self.ensure(identity) orelse return false;
    agent.applyManaged(state);
    return self.reproject(agent, state.observed_at_ms);
}
