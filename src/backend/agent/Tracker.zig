const RepositoryType = @import("Repository.zig");
const RestoredTitlesType = @import("RestoredTitles.zig");
const WatchesType = @import("Watches.zig");
const ReportObservationType = @import("ReportObservation.zig");
const IdentityType = @import("Identity.zig");
const SessionReferenceType = @import("SessionReference.zig");
const PaneKeyType = @import("../pane/PaneKey.zig");
const AgentProviderType = @import("telar-core").AgentProvider;
const SessionTitleType = @import("SessionTitle.zig");
const tracker_support = @import("tracker_support.zig");
const ProcessObservationType = @import("ProcessObservation.zig");
const ProxyObservationType = @import("ProxyObservation.zig");
const ScreenObservationType = @import("ScreenObservation.zig");
const std = @import("std");
const max_agent_snapshot_entries = @import("telar-core").max_agent_snapshot_entries;
const AgentSnapshotEntryType = @import("telar-core").AgentSnapshotEntry;
const AgentStatusType = @import("telar-core").AgentStatus;
const JobType = @import("Job.zig");
const ResultType = @import("Result.zig");
const DescriptionFinishedType = @import("DescriptionFinished.zig");
const WatchType = @import("Watch.zig");
const CompletionType = @import("Completion.zig");
const Agent = @import("Agent.zig");
const description = @import("description.zig");
const Tracker = @This();

repository: RepositoryType = .{},
restored_titles: RestoredTitlesType = .{},
watches: WatchesType = .{},
revision: u64 = 1,
sequence: u64 = 0,

/// Applies one official lifecycle report and its optional session
/// reference, then republishes the projection.
///
/// ```zig
/// _ = tracker.observeReport(.{ .identity = identity, .state = .working, .observed_at_ms = now_ms });
/// ```
pub fn observeReport(tracker: *Tracker, observation: ReportObservationType) bool {
    const agent = tracker.ensure(observation.identity) orelse return false;
    var changed = false;
    if (observation.session) |session| {
        changed = agent.applySessionReference(session);
    }

    if (observation.session_file.path.len != 0) {
        if (agent.session_reference) |reference| {
            _ = tracker.watches.put(.{
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

    return tracker.reproject(agent, observation.observed_at_ms) or changed;
}

/// Records the session reference an agent reported for itself. The
/// aggregate is created if the report precedes every other evidence, so a
/// hook that fires before the process is inspected is not lost.
///
/// ```zig
/// if (tracker.observeSessionReference(identity, reference)) noteSessionChange();
/// ```
pub fn observeSessionReference(tracker: *Tracker, identity: IdentityType, reference: SessionReferenceType) bool {
    const agent = tracker.ensure(identity) orelse return false;
    return agent.applySessionReference(reference);
}

/// Returns the provider currently projected for one exact pane generation.
///
/// ```zig
/// const provider = tracker.projectedProvider(key);
/// ```
pub fn projectedProvider(tracker: *const Tracker, key: PaneKeyType) AgentProviderType {
    const agent = tracker.repository.findConst(key) orelse return .unknown;
    return agent.snapshot().provider;
}

/// Returns the session reference reported for one exact pane generation.
///
/// ```zig
/// const reference = tracker.sessionReference(key) orelse return;
/// ```
pub fn sessionReference(tracker: *const Tracker, key: PaneKeyType) ?SessionReferenceType {
    const agent = tracker.repository.findConst(key) orelse return null;
    return agent.session_reference;
}

/// Returns the checkpoint-worthy title of one exact pane generation: a
/// ready generated or manual title, never a placeholder.
///
/// ```zig
/// const title = tracker.durableTitle(key) orelse return;
/// ```
pub fn durableTitle(tracker: *const Tracker, key: PaneKeyType) ?SessionTitleType {
    const agent = tracker.repository.findConst(key) orelse return null;
    return agent.durableTitle();
}

/// Holds a checkpointed title for a restored pane generation until the
/// resumed agent is observed; that aggregate starts with the title ready.
/// Returns `false` when the bounded store is full.
///
/// ```zig
/// _ = tracker.restoreTitle(pane.key(), title);
/// ```
pub fn restoreTitle(tracker: *Tracker, key: PaneKeyType, title: SessionTitleType) bool {
    if (tracker.repository.find(key)) |agent| {
        agent.restoreTitle(title);
        tracker.bumpRevision();
        return true;
    }

    return tracker.restored_titles.put(key, title);
}

/// Marks one exact agent generation as seen and republishes a `done`
/// projection as `ready`. A stale or unknown generation changes nothing.
///
/// ```zig
/// if (tracker.acknowledge(key, now_ms) == .acknowledged) {
///     pumpClients();
/// }
/// ```
pub fn acknowledge(tracker: *Tracker, key: PaneKeyType, now_ms: i64) tracker_support.AcknowledgeResult {
    const agent = tracker.repository.find(key) orelse return .unknown_agent;

    if (!agent.acknowledge()) {
        return .unchanged;
    }

    _ = tracker.reproject(agent, now_ms);
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
pub fn observeProcess(tracker: *Tracker, observation: ProcessObservationType) bool {
    if (observation.provider == .unknown or observation.process_id == 0) {
        return false;
    }

    const agent = tracker.ensure(observation.identity) orelse return false;

    if (!agent.applyProcess(observation)) {
        return false;
    }

    return tracker.reproject(agent, observation.observed_at_ms);
}

/// A foreground process-group change is authoritative session exit. Old
/// proxy and screen evidence belongs to that process and must not keep its
/// sidebar row alive after the shell regains control.
///
/// ```zig
/// _ = tracker.clearProcess(pane_key);
/// ```
pub fn clearProcess(tracker: *Tracker, key: PaneKeyType) bool {
    const agent = tracker.repository.find(key) orelse return false;

    if (!agent.processExited()) {
        return false;
    }

    return tracker.removeStored(key);
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
pub fn observeProxy(tracker: *Tracker, observation: ProxyObservationType) bool {
    if (observation.dialect == .unknown) {
        return false;
    }

    const agent = tracker.resolveProxyAgent(&observation) orelse return false;
    if (!agent.applyProxy(observation)) {
        return false;
    }

    return tracker.reproject(agent, observation.observed_at_ms);
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
pub fn observeScreen(tracker: *Tracker, observation: ScreenObservationType) bool {
    const agent = tracker.repository.find(observation.identity.key) orelse return false;

    if (!agent.applyScreen(observation)) {
        return false;
    }

    return tracker.reproject(agent, observation.observed_at_ms);
}

/// Expires stale evidence across all agents and removes aggregates with no
/// remaining evidence.
///
/// ```zig
/// _ = tracker.expire(now_ms);
/// ```
pub fn expire(tracker: *Tracker, now_ms: i64) bool {
    var changed = false;
    var iterator = tracker.repository.iterator();

    while (iterator.next()) |agent| {
        if (agent.expire(now_ms)) {
            const removed = iterator.removeCurrent();
            std.debug.assert(removed);
            tracker.bumpRevision();
            changed = true;
            continue;
        }

        changed = tracker.reproject(agent, now_ms) or changed;
    }

    return changed;
}

/// Removes one pane generation and clears its sensitive pending input.
///
/// ```zig
/// _ = tracker.remove(pane_key);
/// ```
pub fn remove(tracker: *Tracker, key: PaneKeyType) bool {
    _ = tracker.restored_titles.take(key);
    const agent = tracker.repository.find(key) orelse return false;
    agent.retire();
    return tracker.removeStored(key);
}

/// Copies the current client projections into caller-owned bounded storage.
///
/// ```zig
/// var entries: [max_records]schema.AgentSnapshotEntry = undefined;
/// const snapshot = tracker.snapshot(&entries);
/// ```
pub fn snapshot(tracker: *const Tracker, entries: *[max_agent_snapshot_entries]AgentSnapshotEntryType) []const AgentSnapshotEntryType {
    var count: usize = 0;
    var iterator = tracker.repository.constIterator();

    while (iterator.next()) |agent| {
        entries[count] = agent.snapshot();
        count += 1;
    }

    return entries[0..count];
}

/// Returns the last projected status for one exact pane generation.
///
/// ```zig
/// const status = tracker.projectedStatus(pane_key);
/// ```
pub fn projectedStatus(tracker: *const Tracker, key: PaneKeyType) ?AgentStatusType {
    const agent = tracker.repository.findConst(key) orelse return null;
    return agent.projectedStatus();
}

/// Captures only the first submitted request for an already identified
/// agent. Callers gate this method on explicit description configuration.
///
/// ```zig
/// _ = tracker.observeInput(pane_key, bytes);
/// ```
pub fn observeInput(tracker: *Tracker, key: PaneKeyType, bytes: []const u8) bool {
    const agent = tracker.repository.find(key) orelse return false;
    return agent.observeInput(bytes);
}

/// Starts one bounded job at a time. Invalid captured input deterministically
/// becomes a failed placeholder and is never retried.
///
/// ```zig
/// const job = tracker.nextDescriptionJob();
/// ```
pub fn nextDescriptionJob(tracker: *Tracker) ?JobType {
    var running = tracker.repository.constIterator();

    while (running.next()) |agent| {
        if (agent.hasRunningDescription()) {
            return null;
        }
    }

    var queued = tracker.repository.iterator();

    while (queued.next()) |agent| {
        switch (agent.startDescriptionJob()) {
            .not_queued => {},
            .failed => tracker.bumpRevision(),
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
pub fn finishDescription(tracker: *Tracker, result: *const ResultType) ?DescriptionFinishedType {
    const agent = tracker.repository.find(result.pane) orelse return null;

    const finished = agent.finishDescription(result) orelse return null;

    tracker.bumpRevision();
    return finished;
}

/// Replaces generated or pending title state for one existing agent.
///
/// ```zig
/// _ = try tracker.setManualTitle(pane_key, "Review proxy lifecycle");
/// ```
pub fn setManualTitle(tracker: *Tracker, key: PaneKeyType, value: []const u8) !bool {
    const agent = tracker.repository.find(key) orelse return false;
    try agent.setManualTitle(value);
    tracker.bumpRevision();
    return true;
}

/// Applies the title an agent's hooks reported for one exact pane
/// generation. Like a session reference, the report may precede every
/// other evidence, so the aggregate is created when missing.
///
/// ```zig
/// if (try tracker.reportTitle(identity, "Fix proxy")) noteSessionChange();
/// ```
pub fn reportTitle(tracker: *Tracker, identity: IdentityType, value: []const u8) !bool {
    const agent = tracker.ensure(identity) orelse return false;
    if (!try agent.reportTitle(value)) {
        return false;
    }

    tracker.bumpRevision();
    return true;
}

/// Claims the session file whose probe is most overdue and returns a
/// copy for the worker. A watch whose agent is gone is dropped instead.
///
/// ```zig
/// const watch = tracker.nextSessionFileProbe(now_ms, 1_000) orelse return;
/// ```
pub fn nextSessionFileProbe(tracker: *Tracker, now_ms: i64, interval_ms: i64) ?WatchType {
    while (tracker.watches.stalest(now_ms, interval_ms)) |watch| {
        if (tracker.repository.find(watch.key) == null) {
            _ = tracker.watches.remove(watch.key);
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
pub fn finishSessionFileProbe(tracker: *Tracker, completion: CompletionType, now_ms: i64) bool {
    const watch = tracker.watches.find(completion.key) orelse return false;
    watch.pending = false;
    watch.checked_at_ms = now_ms;
    watch.offset = completion.offset;
    if (!completion.has_title or !watch.remember(completion.titleSlice())) {
        return false;
    }

    const agent = tracker.repository.find(completion.key) orelse {
        _ = tracker.watches.remove(completion.key);
        return false;
    };
    const changed = agent.reportTitle(completion.titleSlice()) catch return false;
    if (changed) {
        tracker.bumpRevision();
    }

    return changed;
}

/// Publishes pane-topology changes that alter the display position of
/// otherwise unchanged agents.
///
/// ```zig
/// tracker.touch();
/// ```
pub fn touch(tracker: *Tracker) void {
    tracker.bumpRevision();
}

fn resolveProxyAgent(tracker: *Tracker, observation: *const ProxyObservationType) ?*Agent {
    return switch (observation.phase) {
        .request_started => tracker.ensure(observation.identity),
        .response_activity, .provider_turn_completed, .response_finished, .request_failed => tracker.repository.find(observation.identity.key),
    };
}

fn ensure(tracker: *Tracker, identity: IdentityType) ?*Agent {
    if (tracker.repository.find(identity.key)) |agent| {
        return agent;
    }

    const agent = tracker.repository.insert(Agent.init(identity)) orelse return null;
    if (tracker.restored_titles.take(identity.key)) |title| {
        agent.restoreTitle(title);
    }

    return agent;
}

fn removeStored(tracker: *Tracker, key: PaneKeyType) bool {
    _ = tracker.watches.remove(key);
    if (!tracker.repository.remove(key)) {
        return false;
    }

    tracker.bumpRevision();
    return true;
}

pub fn reproject(tracker: *Tracker, agent: *Agent, now_ms: i64) bool {
    const previous_sequence = tracker.sequence;
    const result = agent.reproject(.{
        .sequence = tracker.nextSequence(),
        .now_ms = now_ms,
        .can_queue_description = tracker.pendingDescriptionCount() < description.max_pending_jobs,
    });

    switch (result) {
        .no_evidence => {
            tracker.sequence = previous_sequence;
            return false;
        },
        .unchanged => return false,
        .changed => {},
    }

    tracker.bumpRevision();
    return true;
}

fn pendingDescriptionCount(tracker: *const Tracker) usize {
    var count: usize = 0;
    var iterator = tracker.repository.constIterator();

    while (iterator.next()) |agent| {
        if (agent.hasPendingDescription()) {
            count += 1;
        }
    }

    return count;
}

fn nextSequence(tracker: *Tracker) u64 {
    tracker.sequence +%= 1;

    if (tracker.sequence == 0) {
        tracker.sequence = 1;
    }

    return tracker.sequence;
}

fn bumpRevision(tracker: *Tracker) void {
    tracker.revision +%= 1;

    if (tracker.revision == 0) {
        tracker.revision = 1;
    }
}
