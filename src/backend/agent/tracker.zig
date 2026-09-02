//! Runtime-owned coordinator for agent observations and projections.
//!
//! The tracker resolves observations to one pane generation, delegates every
//! state transition to that aggregate, and publishes revisioned snapshots.

const std = @import("std");
const core = @import("telar-core");
const Agent = @import("agent.zig");
const pane_mod = @import("../pane/root.zig");
const repository_mod = @import("repository.zig");
const types = @import("types.zig");
const description = @import("description.zig");

const schema = core.schema;
const PaneKey = pane_mod.PaneKey;
const max_records = types.max_records;
const settled_expiry_ms = types.settled_expiry_ms;
const Identity = types.Identity;
const ProcessObservation = types.ProcessObservation;
const ScreenObservation = types.ScreenObservation;
const ProxyPhase = types.ProxyPhase;
const ProxyExchange = types.ProxyExchange;
const ProxyObservation = types.ProxyObservation;
const DescriptionFinished = types.DescriptionFinished;
const Repository = repository_mod.Repository;

pub const AcknowledgeResult = enum {
    unknown_agent,
    unchanged,
    acknowledged,
};

pub const Tracker = struct {
    repository: Repository = .{},
    revision: u64 = 1,
    sequence: u64 = 0,

    /// Applies one official lifecycle report and its optional session
    /// reference, then republishes the projection.
    ///
    /// ```zig
    /// _ = tracker.observeReport(.{ .identity = identity, .state = .working, .observed_at_ms = now_ms });
    /// ```
    pub fn observeReport(tracker: *Tracker, observation: types.ReportObservation) bool {
        const agent = tracker.ensure(observation.identity) orelse return false;
        var changed = false;
        if (observation.session) |session| {
            changed = agent.applySessionReference(session);
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
    pub fn observeSessionReference(tracker: *Tracker, identity: Identity, reference: types.SessionReference) bool {
        const agent = tracker.ensure(identity) orelse return false;
        return agent.applySessionReference(reference);
    }

    /// Returns the provider currently projected for one exact pane generation.
    ///
    /// ```zig
    /// const provider = tracker.projectedProvider(key);
    /// ```
    pub fn projectedProvider(tracker: *const Tracker, key: PaneKey) schema.AgentProvider {
        const agent = tracker.repository.findConst(key) orelse return .unknown;
        return agent.snapshot().provider;
    }

    /// Returns the session reference reported for one exact pane generation.
    ///
    /// ```zig
    /// const reference = tracker.sessionReference(key) orelse return;
    /// ```
    pub fn sessionReference(tracker: *const Tracker, key: PaneKey) ?types.SessionReference {
        const agent = tracker.repository.findConst(key) orelse return null;
        return agent.session_reference;
    }

    /// Marks one exact agent generation as seen and republishes a `done`
    /// projection as `ready`. A stale or unknown generation changes nothing.
    ///
    /// ```zig
    /// if (tracker.acknowledge(key, now_ms) == .acknowledged) {
    ///     pumpClients();
    /// }
    /// ```
    pub fn acknowledge(tracker: *Tracker, key: PaneKey, now_ms: i64) AcknowledgeResult {
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
    pub fn observeProcess(tracker: *Tracker, observation: ProcessObservation) bool {
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
    pub fn clearProcess(tracker: *Tracker, key: PaneKey) bool {
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
    pub fn observeProxy(tracker: *Tracker, observation: ProxyObservation) bool {
        if (observation.provider == .unknown) {
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
    pub fn observeScreen(tracker: *Tracker, observation: ScreenObservation) bool {
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
    pub fn remove(tracker: *Tracker, key: PaneKey) bool {
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
    pub fn snapshot(tracker: *const Tracker, entries: *[max_records]schema.AgentSnapshotEntry) []const schema.AgentSnapshotEntry {
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
    pub fn projectedStatus(tracker: *const Tracker, key: PaneKey) ?schema.AgentStatus {
        const agent = tracker.repository.findConst(key) orelse return null;
        return agent.projectedStatus();
    }

    /// Captures only the first submitted request for an already identified
    /// agent. Callers gate this method on explicit description configuration.
    ///
    /// ```zig
    /// _ = tracker.observeInput(pane_key, bytes);
    /// ```
    pub fn observeInput(tracker: *Tracker, key: PaneKey, bytes: []const u8) bool {
        const agent = tracker.repository.find(key) orelse return false;
        return agent.observeInput(bytes);
    }

    /// Starts one bounded job at a time. Invalid captured input deterministically
    /// becomes a failed placeholder and is never retried.
    ///
    /// ```zig
    /// const job = tracker.nextDescriptionJob();
    /// ```
    pub fn nextDescriptionJob(tracker: *Tracker) ?description.Job {
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
    pub fn finishDescription(tracker: *Tracker, result: *const description.Result) ?DescriptionFinished {
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
    pub fn setManualTitle(tracker: *Tracker, key: PaneKey, value: []const u8) !bool {
        const agent = tracker.repository.find(key) orelse return false;
        try agent.setManualTitle(value);
        tracker.bumpRevision();
        return true;
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

    fn resolveProxyAgent(tracker: *Tracker, observation: *const ProxyObservation) ?*Agent {
        return switch (observation.phase) {
            .request_started => tracker.ensure(observation.identity),
            .response_activity, .provider_turn_completed, .response_finished, .request_failed => tracker.repository.find(observation.identity.key),
        };
    }

    fn ensure(tracker: *Tracker, identity: Identity) ?*Agent {
        if (tracker.repository.find(identity.key)) |agent| {
            return agent;
        }

        return tracker.repository.insert(Agent.init(identity));
    }

    fn removeStored(tracker: *Tracker, key: PaneKey) bool {
        if (!tracker.repository.remove(key)) {
            return false;
        }

        tracker.bumpRevision();
        return true;
    }

    fn reproject(tracker: *Tracker, agent: *Agent, now_ms: i64) bool {
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
};

fn testIdentity() !Identity {
    return .{
        .key = .{ .id = try schema.id.pane(7), .generation = 3 },
        .process_id = 42,
        .session_id = .{0xa5} ** 16,
    };
}

fn testIdentityAt(id: u32, generation: u64) !Identity {
    return .{
        .key = .{ .id = try schema.id.pane(id), .generation = generation },
        .process_id = id,
        .session_id = .{@as(u8, @intCast(id))} ** 16,
    };
}

const TestProxyObservation = struct {
    provider: schema.AgentProvider,
    phase: ProxyPhase,
    observed_at_ms: i64,
};

const TestReadyPrompt = struct {
    provider: schema.AgentProvider,
    observed_at_ms: i64,
};

fn testProxy(provider: schema.AgentProvider, phase: ProxyPhase, observed_at_ms: i64) TestProxyObservation {
    return .{ .provider = provider, .phase = phase, .observed_at_ms = observed_at_ms };
}

fn testReadyPrompt(provider: schema.AgentProvider, observed_at_ms: i64) TestReadyPrompt {
    return .{ .provider = provider, .observed_at_ms = observed_at_ms };
}

fn observeTestProxy(tracker: *Tracker, identity: Identity, observation: TestProxyObservation) bool {
    return tracker.observeProxy(.{
        .identity = identity,
        .provider = observation.provider,
        .phase = observation.phase,
        .observed_at_ms = observation.observed_at_ms,
        .exchange = .{
            .protocol = .h2,
            .connection_id = 1,
            .stream_id = 1,
        },
    });
}

fn observeTestReadyPrompt(tracker: *Tracker, identity: Identity, prompt: TestReadyPrompt) bool {
    return tracker.observeScreen(.{
        .identity = identity,
        .signal = .{
            .provider = prompt.provider,
            .status = .ready,
            .confidence = 96,
            .identity_confirmed = true,
            .ready_confirmed = true,
        },
        .observed_at_ms = prompt.observed_at_ms,
    });
}

test "display context changes advance the public snapshot revision" {
    var tracker: Tracker = .{};
    const before = tracker.revision;
    tracker.touch();
    try std.testing.expectEqual(before + 1, tracker.revision);
}

test "an agent without evidence does not consume a projection sequence" {
    var tracker: Tracker = .{ .sequence = 41 };
    var agent = Agent.init(try testIdentity());

    try std.testing.expect(!tracker.reproject(&agent, 100));
    try std.testing.expectEqual(@as(u64, 41), tracker.sequence);
    try std.testing.expectEqual(@as(u64, 1), tracker.revision);
}

test "tracker rejects every observation that would exceed repository capacity" {
    var tracker: Tracker = .{};

    for (0..max_records) |index| {
        const identity = try testIdentityAt(@intCast(index + 1), 1);
        try std.testing.expect(tracker.observeProcess(.{
            .identity = identity,
            .provider = .claude,
            .process_id = identity.process_id,
            .observed_at_ms = 100,
        }));
    }

    const overflow = try testIdentityAt(@intCast(max_records + 1), 1);
    try std.testing.expect(!tracker.observeProcess(.{
        .identity = overflow,
        .provider = .claude,
        .process_id = overflow.process_id,
        .observed_at_ms = 200,
    }));
    try std.testing.expect(!tracker.observeScreen(.{
        .identity = overflow,
        .signal = .{
            .provider = .claude,
            .status = .ready,
            .confidence = 96,
            .identity_confirmed = true,
            .ready_confirmed = true,
        },
        .observed_at_ms = 200,
    }));
    try std.testing.expect(!observeTestProxy(&tracker, overflow, testProxy(.claude, .request_started, 200)));

    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    try std.testing.expectEqual(max_records, tracker.snapshot(&entries).len);
}

test "only a confirmed prompt settles model work" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    try std.testing.expect(observeTestProxy(&tracker, identity, testProxy(.claude, .request_started, 100)));
    try std.testing.expect(observeTestProxy(&tracker, identity, testProxy(.claude, .response_finished, 200)));
    try std.testing.expect(!tracker.observeScreen(.{
        .identity = identity,
        .signal = .{
            .provider = .claude,
            .status = .ready,
            .confidence = 90,
            .identity_confirmed = true,
        },
        .observed_at_ms = 300,
    }));
    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    var snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(@as(usize, 1), snapshot.len);
    try std.testing.expectEqual(schema.AgentStatus.working, snapshot[0].status);
    try std.testing.expectEqual(schema.AgentSource.proxy_tls, snapshot[0].source);

    try std.testing.expect(observeTestReadyPrompt(&tracker, identity, testReadyPrompt(.claude, 400)));
    snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentStatus.done, snapshot[0].status);
    try std.testing.expectEqual(schema.AgentSource.screen, snapshot[0].source);
}

test "explicit Codex prompt settles working without repetition" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    try std.testing.expect(observeTestProxy(&tracker, identity, testProxy(.codex, .request_started, 100)));
    try std.testing.expect(tracker.observeScreen(.{
        .identity = identity,
        .signal = .{
            .provider = .codex,
            .status = .ready,
            .confidence = 94,
            .identity_confirmed = true,
            .ready_confirmed = true,
        },
        .observed_at_ms = 200,
    }));

    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    const snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentStatus.done, snapshot[0].status);
    try std.testing.expectEqual(schema.AgentSource.screen, snapshot[0].source);
}

test "agent branding alone does not settle working" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    try std.testing.expect(observeTestProxy(&tracker, identity, testProxy(.claude, .request_started, 100)));
    try std.testing.expect(!tracker.observeScreen(.{
        .identity = identity,
        .signal = .{
            .provider = .claude,
            .status = .ready,
            .confidence = 90,
            .identity_confirmed = true,
        },
        .observed_at_ms = 200,
    }));

    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    const snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentStatus.working, snapshot[0].status);
    try std.testing.expectEqual(schema.AgentSource.proxy_tls, snapshot[0].source);
}

test "screen text cannot register an agent without independent evidence" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    try std.testing.expect(!tracker.observeScreen(.{
        .identity = identity,
        .signal = .{
            .provider = .claude,
            .status = .ready,
            .confidence = 94,
            .identity_confirmed = true,
        },
        .observed_at_ms = 100,
    }));
    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    const snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(@as(usize, 0), snapshot.len);
}

test "foreground process establishes agent identity without screen branding" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    try std.testing.expect(tracker.observeProcess(.{
        .identity = identity,
        .provider = .claude,
        .process_id = 84,
        .observed_at_ms = 100,
    }));

    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    var snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(@as(usize, 1), snapshot.len);
    try std.testing.expectEqual(schema.AgentProvider.claude, snapshot[0].provider);
    try std.testing.expectEqual(schema.AgentStatus.ready, snapshot[0].status);
    try std.testing.expectEqual(schema.AgentSource.foreground_process, snapshot[0].source);
    try std.testing.expectEqual(@as(u32, 84), snapshot[0].process_id);

    try std.testing.expect(tracker.observeScreen(.{
        .identity = identity,
        .signal = .{ .provider = .unknown, .status = .working, .confidence = 78 },
        .observed_at_ms = 200,
    }));
    snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentProvider.claude, snapshot[0].provider);
    try std.testing.expectEqual(schema.AgentStatus.working, snapshot[0].status);
    try std.testing.expectEqual(schema.AgentSource.screen, snapshot[0].source);
    try std.testing.expectEqual(@as(u32, 84), snapshot[0].process_id);
}

test "first working turn starts one generated session title" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    try std.testing.expect(tracker.observeProcess(.{
        .identity = identity,
        .provider = .codex,
        .process_id = 84,
        .observed_at_ms = 100,
    }));
    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    var snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqualStrings("New Codex session", snapshot[0].session_title);
    try std.testing.expectEqual(schema.AgentTitleState.placeholder, snapshot[0].title_state);

    try std.testing.expect(tracker.observeInput(identity.key, "improve the sidebar\r"));
    try std.testing.expect(observeTestReadyPrompt(&tracker, identity, testReadyPrompt(.codex, 150)));
    snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentTitleState.placeholder, snapshot[0].title_state);

    try std.testing.expect(observeTestProxy(&tracker, identity, testProxy(.codex, .request_started, 200)));
    snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentTitleState.pending, snapshot[0].title_state);

    var job = tracker.nextDescriptionJob().?;
    defer std.crypto.secureZero(u8, &job.query);
    try std.testing.expectEqualStrings("improve the sidebar", job.querySlice());
    var result: description.Result = .{
        .pane = job.pane,
        .session_id = job.session_id,
        .status = .success,
        .title_len = "Improve agent sidebar".len,
    };
    @memcpy(result.title[0..result.title_len], "Improve agent sidebar");
    const finished = tracker.finishDescription(&result).?;
    @memset(result.title[0..result.title_len], 'x');
    try std.testing.expectEqualDeep(job.pane, finished.pane);
    try std.testing.expectEqualSlices(u8, &job.session_id, &finished.session_id);
    try std.testing.expectEqualStrings("Improve agent sidebar", finished.titleSlice());
    try std.testing.expectEqual(schema.AgentTitleSource.generated, finished.source);
    try std.testing.expectEqual(schema.AgentTitleState.ready, finished.state);
    snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqualStrings("Improve agent sidebar", snapshot[0].session_title);
    try std.testing.expectEqual(schema.AgentTitleSource.generated, snapshot[0].title_source);
    try std.testing.expectEqual(schema.AgentTitleState.ready, snapshot[0].title_state);
    try std.testing.expect(tracker.nextDescriptionJob() == null);
}

test "manual title wins over a late generated result" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    try std.testing.expect(tracker.observeProcess(.{
        .identity = identity,
        .provider = .claude,
        .process_id = 84,
        .observed_at_ms = 100,
    }));
    try std.testing.expect(tracker.observeInput(identity.key, "fix tests\r"));
    try std.testing.expect(observeTestProxy(&tracker, identity, testProxy(.claude, .request_started, 200)));
    var job = tracker.nextDescriptionJob().?;
    defer std.crypto.secureZero(u8, &job.query);
    try std.testing.expect(try tracker.setManualTitle(identity.key, "Release audit"));

    var result: description.Result = .{
        .pane = job.pane,
        .session_id = job.session_id,
        .status = .success,
        .title_len = "Generated title".len,
    };
    @memcpy(result.title[0..result.title_len], "Generated title");
    try std.testing.expect(tracker.finishDescription(&result) == null);
    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    const snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqualStrings("Release audit", snapshot[0].session_title);
    try std.testing.expectEqual(schema.AgentTitleSource.manual, snapshot[0].title_source);
}

test "description backpressure fails the ninth queued request without retry" {
    var tracker: Tracker = .{};
    for (0..description.max_pending_jobs + 1) |index| {
        const raw: u64 = @intCast(index + 1);
        const identity: Identity = .{
            .key = .{ .id = try schema.id.pane(raw), .generation = raw },
            .process_id = @intCast(raw),
            .session_id = @splat(@intCast(raw)),
        };
        try std.testing.expect(tracker.observeProcess(.{
            .identity = identity,
            .provider = .codex,
            .process_id = @intCast(raw),
            .observed_at_ms = 100,
        }));
        try std.testing.expect(tracker.observeInput(identity.key, "do work\r"));
        try std.testing.expect(observeTestProxy(&tracker, identity, testProxy(.codex, .request_started, 200)));
    }
    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    const snapshot = tracker.snapshot(&entries);
    var pending: usize = 0;
    var failed: usize = 0;
    for (snapshot) |entry| switch (entry.title_state) {
        .pending => pending += 1,
        .failed => failed += 1,
        else => {},
    };
    try std.testing.expectEqual(description.max_pending_jobs, pending);
    try std.testing.expectEqual(@as(usize, 1), failed);
}

test "process identity rejects contradictory screen branding" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    try std.testing.expect(tracker.observeProcess(.{
        .identity = identity,
        .provider = .claude,
        .process_id = 84,
        .observed_at_ms = 100,
    }));
    try std.testing.expect(!tracker.observeScreen(.{
        .identity = identity,
        .signal = .{
            .provider = .codex,
            .status = .ready,
            .confidence = 94,
            .identity_confirmed = true,
        },
        .observed_at_ms = 200,
    }));

    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    const snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentProvider.claude, snapshot[0].provider);
    try std.testing.expectEqual(schema.AgentSource.foreground_process, snapshot[0].source);
}

test "foreground process exit removes all evidence for that session" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    try std.testing.expect(tracker.observeProcess(.{
        .identity = identity,
        .provider = .claude,
        .process_id = 84,
        .observed_at_ms = 100,
    }));
    try std.testing.expect(tracker.observeScreen(.{
        .identity = identity,
        .signal = .{ .provider = .unknown, .status = .blocked, .confidence = 88 },
        .observed_at_ms = 200,
    }));
    try std.testing.expect(tracker.clearProcess(identity.key));

    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    try std.testing.expectEqual(@as(usize, 0), tracker.snapshot(&entries).len);
}

test "new foreground process replaces prior session evidence" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    try std.testing.expect(tracker.observeProcess(.{
        .identity = identity,
        .provider = .claude,
        .process_id = 84,
        .observed_at_ms = 100,
    }));
    try std.testing.expect(tracker.observeScreen(.{
        .identity = identity,
        .signal = .{ .provider = .unknown, .status = .blocked, .confidence = 88 },
        .observed_at_ms = 200,
    }));
    try std.testing.expect(tracker.observeProcess(.{
        .identity = identity,
        .provider = .codex,
        .process_id = 85,
        .observed_at_ms = 300,
    }));

    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    const snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentProvider.codex, snapshot[0].provider);
    try std.testing.expectEqual(schema.AgentStatus.ready, snapshot[0].status);
    try std.testing.expectEqual(schema.AgentSource.foreground_process, snapshot[0].source);
    try std.testing.expectEqual(schema.AgentAuthority.active, snapshot[0].authority);
    try std.testing.expectEqual(@as(u32, 85), snapshot[0].process_id);
}

test "confirmed Claude prompt refreshes branded identity" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    try std.testing.expect(tracker.observeProcess(.{
        .identity = identity,
        .provider = .claude,
        .process_id = 84,
        .observed_at_ms = 50,
    }));
    try std.testing.expect(tracker.observeScreen(.{
        .identity = identity,
        .signal = .{
            .provider = .claude,
            .status = .ready,
            .confidence = 90,
            .identity_confirmed = true,
        },
        .observed_at_ms = 100,
    }));
    try std.testing.expect(observeTestReadyPrompt(&tracker, identity, testReadyPrompt(.claude, 200)));
    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    const snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(@as(usize, 1), snapshot.len);
    try std.testing.expectEqual(schema.AgentProvider.claude, snapshot[0].provider);
    try std.testing.expectEqual(schema.AgentStatus.ready, snapshot[0].status);
    try std.testing.expectEqual(@as(i64, 200), snapshot[0].observed_at_ms);
}

test "network work resumes a visibly blocked agent" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    try std.testing.expect(tracker.observeProcess(.{
        .identity = identity,
        .provider = .claude,
        .process_id = 84,
        .observed_at_ms = 50,
    }));
    try std.testing.expect(tracker.observeScreen(.{
        .identity = identity,
        .signal = .{ .provider = .claude, .status = .blocked, .confidence = 88 },
        .observed_at_ms = 100,
    }));
    try std.testing.expect(observeTestProxy(&tracker, identity, testProxy(.claude, .request_started, 200)));
    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    const snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentStatus.working, snapshot[0].status);
    try std.testing.expectEqual(schema.AgentAuthority.resumed, snapshot[0].authority);
}

test "new network work supersedes an older ready prompt" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    try std.testing.expect(observeTestProxy(&tracker, identity, testProxy(.claude, .request_started, 50)));
    try std.testing.expect(observeTestProxy(&tracker, identity, testProxy(.claude, .response_finished, 100)));
    try std.testing.expect(observeTestReadyPrompt(&tracker, identity, testReadyPrompt(.claude, 200)));
    try std.testing.expect(observeTestProxy(&tracker, identity, testProxy(.claude, .request_started, 300)));
    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    const snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentStatus.working, snapshot[0].status);
    try std.testing.expectEqual(schema.AgentSource.proxy_tls, snapshot[0].source);
}

test "unmatched proxy responses cannot create agent state" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    const exchange: ProxyExchange = .{ .protocol = .h2, .connection_id = 9, .stream_id = 3 };
    try std.testing.expect(!tracker.observeProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .response_activity,
        .exchange = exchange,
        .observed_at_ms = 100,
    }));
    try std.testing.expect(!tracker.observeProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .provider_turn_completed,
        .exchange = exchange,
        .observed_at_ms = 200,
    }));
    try std.testing.expect(!tracker.observeProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .request_failed,
        .exchange = exchange,
        .observed_at_ms = 300,
    }));

    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    try std.testing.expectEqual(@as(usize, 0), tracker.snapshot(&entries).len);
}

test "a contradictory provider cannot complete another agent's exchange" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    const exchange: ProxyExchange = .{ .protocol = .h2, .connection_id = 9, .stream_id = 1 };

    _ = tracker.observeProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .request_started,
        .exchange = exchange,
        .observed_at_ms = 100,
    });
    try std.testing.expect(!tracker.observeProxy(.{
        .identity = identity,
        .provider = .codex,
        .phase = .provider_turn_completed,
        .exchange = exchange,
        .observed_at_ms = 200,
    }));

    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    var snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentProvider.claude, snapshot[0].provider);
    try std.testing.expectEqual(schema.AgentStatus.working, snapshot[0].status);

    try std.testing.expect(tracker.observeProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .provider_turn_completed,
        .exchange = exchange,
        .observed_at_ms = 300,
    }));
    snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentProvider.claude, snapshot[0].provider);
    try std.testing.expectEqual(schema.AgentStatus.done, snapshot[0].status);
}

test "transport completion without provider turn completion remains working" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    const exchange: ProxyExchange = .{ .protocol = .h2, .connection_id = 9, .stream_id = 1 };

    try std.testing.expect(tracker.observeProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .request_started,
        .exchange = exchange,
        .observed_at_ms = 100,
    }));
    try std.testing.expect(tracker.observeProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .response_finished,
        .exchange = exchange,
        .observed_at_ms = 200,
    }));

    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    const snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(@as(usize, 1), snapshot.len);
    try std.testing.expectEqual(schema.AgentStatus.working, snapshot[0].status);
    try std.testing.expectEqual(schema.AgentSource.proxy_tls, snapshot[0].source);
    try std.testing.expectEqual(@as(i64, 200), snapshot[0].observed_at_ms);
}

test "provider turn completion projects ready and ignores later transport completion" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    const exchange: ProxyExchange = .{ .protocol = .h2, .connection_id = 9, .stream_id = 1 };

    try std.testing.expect(tracker.observeProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .request_started,
        .exchange = exchange,
        .observed_at_ms = 100,
    }));
    try std.testing.expect(tracker.observeProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .provider_turn_completed,
        .exchange = exchange,
        .observed_at_ms = 200,
    }));

    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    var snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentStatus.done, snapshot[0].status);
    try std.testing.expectEqual(schema.AgentSource.proxy_tls, snapshot[0].source);
    try std.testing.expectEqual(@as(u8, 99), snapshot[0].confidence);
    try std.testing.expectEqual(@as(i64, 200), snapshot[0].observed_at_ms);

    try std.testing.expect(!tracker.observeProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .response_finished,
        .exchange = exchange,
        .observed_at_ms = 300,
    }));
    snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentStatus.done, snapshot[0].status);
    try std.testing.expectEqual(@as(i64, 200), snapshot[0].observed_at_ms);
}

test "all concurrent model exchanges must complete before ready" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    const first: ProxyExchange = .{ .protocol = .h2, .connection_id = 9, .stream_id = 1 };
    const second: ProxyExchange = .{ .protocol = .h2, .connection_id = 9, .stream_id = 3 };

    for ([_]ProxyExchange{ first, second }, 0..) |exchange, index| {
        try std.testing.expect(tracker.observeProxy(.{
            .identity = identity,
            .provider = .claude,
            .phase = .request_started,
            .exchange = exchange,
            .observed_at_ms = @intCast(100 + index),
        }));
    }

    try std.testing.expect(tracker.observeProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .provider_turn_completed,
        .exchange = first,
        .observed_at_ms = 200,
    }));
    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    var snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentStatus.working, snapshot[0].status);

    try std.testing.expect(tracker.observeProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .provider_turn_completed,
        .exchange = second,
        .observed_at_ms = 300,
    }));
    snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentStatus.done, snapshot[0].status);
}

test "new model work supersedes a completed response" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    const completed: ProxyExchange = .{ .protocol = .h2, .connection_id = 9, .stream_id = 1 };
    const next: ProxyExchange = .{ .protocol = .h2, .connection_id = 9, .stream_id = 3 };

    _ = tracker.observeProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .request_started,
        .exchange = completed,
        .observed_at_ms = 100,
    });
    _ = tracker.observeProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .provider_turn_completed,
        .exchange = completed,
        .observed_at_ms = 200,
    });
    try std.testing.expect(tracker.observeProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .request_started,
        .exchange = next,
        .observed_at_ms = 300,
    }));

    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    const snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentStatus.working, snapshot[0].status);
    try std.testing.expectEqual(@as(i64, 300), snapshot[0].observed_at_ms);
}

test "expired agent evidence is removed" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    try std.testing.expect(observeTestProxy(&tracker, identity, testProxy(.codex, .request_started, 50)));
    try std.testing.expect(observeTestProxy(&tracker, identity, testProxy(.codex, .response_finished, 100)));
    try std.testing.expect(tracker.expire(100 + settled_expiry_ms));
    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    try std.testing.expectEqual(@as(usize, 0), tracker.snapshot(&entries).len);
}

test "expiration removes every adjacent stale aggregate" {
    var tracker: Tracker = .{};
    const first = try testIdentityAt(1, 1);
    const second = try testIdentityAt(2, 1);

    try std.testing.expect(observeTestProxy(&tracker, first, testProxy(.codex, .request_started, 50)));
    try std.testing.expect(observeTestProxy(&tracker, first, testProxy(.codex, .response_finished, 100)));
    try std.testing.expect(observeTestProxy(&tracker, second, testProxy(.codex, .request_started, 50)));
    try std.testing.expect(observeTestProxy(&tracker, second, testProxy(.codex, .response_finished, 100)));
    try std.testing.expect(tracker.expire(100 + settled_expiry_ms));

    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    try std.testing.expectEqual(@as(usize, 0), tracker.snapshot(&entries).len);
}

test "a bare shell prompt is not Claude identity" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    try std.testing.expect(!tracker.observeScreen(.{
        .identity = identity,
        .signal = .{ .provider = .claude, .status = .ready, .confidence = 72 },
        .observed_at_ms = 100,
    }));
    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    try std.testing.expectEqual(@as(usize, 0), tracker.snapshot(&entries).len);
}

test "completed HTTP2 streams do not settle the agent turn" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    const first: ProxyExchange = .{ .protocol = .h2, .connection_id = 9, .stream_id = 1 };
    const second: ProxyExchange = .{ .protocol = .h2, .connection_id = 9, .stream_id = 3 };
    try std.testing.expect(tracker.observeProxy(.{
        .identity = identity,
        .provider = .codex,
        .phase = .request_started,
        .exchange = first,
        .observed_at_ms = 100,
    }));
    _ = tracker.observeProxy(.{
        .identity = identity,
        .provider = .codex,
        .phase = .request_started,
        .exchange = second,
        .observed_at_ms = 101,
    });
    _ = tracker.observeProxy(.{
        .identity = identity,
        .provider = .codex,
        .phase = .response_finished,
        .exchange = first,
        .observed_at_ms = 200,
    });

    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    var snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentStatus.working, snapshot[0].status);
    _ = tracker.observeProxy(.{
        .identity = identity,
        .provider = .codex,
        .phase = .response_finished,
        .exchange = second,
        .observed_at_ms = 300,
    });
    snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentStatus.working, snapshot[0].status);

    try std.testing.expect(observeTestReadyPrompt(&tracker, identity, testReadyPrompt(.codex, 400)));
    snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentStatus.done, snapshot[0].status);
}

test "sequential model requests stay working until a confirmed prompt" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    const first: ProxyExchange = .{ .protocol = .h2, .connection_id = 9, .stream_id = 1 };
    const second: ProxyExchange = .{ .protocol = .h2, .connection_id = 9, .stream_id = 3 };
    try std.testing.expect(tracker.observeProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .request_started,
        .exchange = first,
        .observed_at_ms = 100,
    }));
    try std.testing.expect(tracker.observeProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .response_finished,
        .exchange = first,
        .observed_at_ms = 200,
    }));

    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    var snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentStatus.working, snapshot[0].status);

    try std.testing.expect(tracker.observeProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .request_started,
        .exchange = second,
        .observed_at_ms = 300,
    }));
    try std.testing.expect(tracker.observeProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .response_finished,
        .exchange = second,
        .observed_at_ms = 400,
    }));
    snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentStatus.working, snapshot[0].status);

    try std.testing.expect(observeTestReadyPrompt(&tracker, identity, testReadyPrompt(.claude, 500)));
    snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentStatus.done, snapshot[0].status);
    try std.testing.expectEqual(schema.AgentSource.screen, snapshot[0].source);
}

test "HTTP2 connection failure settles all of its active streams" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    const first: ProxyExchange = .{ .protocol = .h2, .connection_id = 11, .stream_id = 1 };
    const second: ProxyExchange = .{ .protocol = .h2, .connection_id = 11, .stream_id = 3 };
    const connection: ProxyExchange = .{ .protocol = .h2, .connection_id = 11, .stream_id = 0 };
    _ = tracker.observeProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .request_started,
        .exchange = first,
        .observed_at_ms = 100,
    });
    _ = tracker.observeProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .request_started,
        .exchange = second,
        .observed_at_ms = 101,
    });
    try std.testing.expect(tracker.observeProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .request_failed,
        .exchange = connection,
        .observed_at_ms = 200,
    }));
    try std.testing.expect(!tracker.observeProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .request_failed,
        .exchange = connection,
        .observed_at_ms = 201,
    }));
}

test "session references attach to the exact generation and replace only on change" {
    var tracker: Tracker = .{};
    const identity: Identity = .{
        .key = .{ .id = try schema.id.pane(3), .generation = 2 },
        .process_id = 40,
        .session_id = .{1} ** 16,
    };
    const first = try types.SessionReference.init("0192aaaa-bbbb-cccc-dddd-eeeeffff0000", 10);

    try std.testing.expect(tracker.observeSessionReference(identity, first));
    try std.testing.expect(!tracker.observeSessionReference(identity, first));
    try std.testing.expectEqualStrings(first.slice(), tracker.sessionReference(identity.key).?.slice());
    try std.testing.expect(tracker.sessionReference(.{ .id = identity.key.id, .generation = 3 }) == null);

    const second = try types.SessionReference.init("0192aaaa-bbbb-cccc-dddd-eeeeffff0001", 20);
    try std.testing.expect(tracker.observeSessionReference(identity, second));
    try std.testing.expectError(error.InvalidSessionReference, types.SessionReference.init("-rf", 0));
    try std.testing.expectError(error.InvalidSessionReference, types.SessionReference.init("a b", 0));
}

test "lifecycle reports outrank screen and proxy evidence until they expire" {
    var tracker: Tracker = .{};
    const identity: Identity = .{
        .key = .{ .id = try schema.id.pane(5), .generation = 1 },
        .process_id = 40,
        .session_id = .{2} ** 16,
    };
    try std.testing.expect(tracker.observeProcess(.{ .identity = identity, .provider = .claude, .process_id = 41, .observed_at_ms = 100 }));
    try std.testing.expect(tracker.observeScreen(.{
        .identity = identity,
        .signal = .{ .provider = .claude, .status = .blocked, .confidence = 88, .identity_confirmed = true },
        .observed_at_ms = 200,
    }));
    try std.testing.expectEqual(schema.AgentStatus.blocked, tracker.projectedStatus(identity.key).?);

    try std.testing.expect(tracker.observeReport(.{ .identity = identity, .state = .working, .observed_at_ms = 300 }));
    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    var snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentStatus.working, snapshot[0].status);
    try std.testing.expectEqual(schema.AgentSource.lifecycle_report, snapshot[0].source);
    try std.testing.expectEqual(schema.AgentProvider.claude, snapshot[0].provider);

    try std.testing.expect(tracker.observeReport(.{ .identity = identity, .state = .ready, .observed_at_ms = 400 }));
    try std.testing.expectEqual(schema.AgentStatus.done, tracker.projectedStatus(identity.key).?);

    try std.testing.expect(tracker.observeReport(.{ .identity = identity, .state = .exited, .observed_at_ms = 500 }));
    snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentStatus.blocked, snapshot[0].status);
    try std.testing.expectEqual(schema.AgentSource.screen, snapshot[0].source);

    try std.testing.expect(tracker.observeReport(.{ .identity = identity, .state = .working, .observed_at_ms = 600 }));
    _ = tracker.expire(600 + types.working_expiry_ms + 1);
    snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentSource.screen, snapshot[0].source);
}
