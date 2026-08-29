//! One runtime-owned agent aggregate.
//!
//! Every process, proxy, screen, title, authority, and projection mutation for
//! one pane generation crosses this type.

const std = @import("std");
const core = @import("telar-core");
const description = @import("description.zig");
const evidence_mod = @import("evidence.zig");
const pane_mod = @import("../pane/root.zig");
const proxy_state_mod = @import("proxy_state.zig");
const types = @import("types.zig");

const Agent = @This();
const Evidence = evidence_mod.Evidence;
const Identity = types.Identity;
const PaneKey = pane_mod.PaneKey;
const ProcessObservation = types.ProcessObservation;
const ProxyExchange = types.ProxyExchange;
const ProxyObservation = types.ProxyObservation;
const ProxyState = proxy_state_mod.ProxyState;
const ScreenObservation = types.ScreenObservation;
const schema = core.schema;

pub const ProjectionContext = struct {
    sequence: u64,
    now_ms: i64,
    can_queue_description: bool,
};

pub const ProjectionResult = enum {
    no_evidence,
    unchanged,
    changed,
};

pub const DescriptionJobResult = union(enum) {
    not_queued,
    failed,
    started: description.Job,
};

const TitlePhase = enum {
    waiting_query,
    waiting_work,
    queued,
    running,
    finished,
    failed,
};

const Title = struct {
    bytes: [schema.max_agent_session_title_bytes]u8 = undefined,
    len: u8 = 0,
    source: schema.AgentTitleSource = .telar,
    state: schema.AgentTitleState = .placeholder,
    phase: TitlePhase = .waiting_query,
    capture: description.Capture = .{},

    fn slice(title: *const Title) []const u8 {
        return title.bytes[0..title.len];
    }

    fn clearSensitive(title: *Title) void {
        title.capture.clear();
    }
};

key: PaneKey,
process_id: u32,
agent_process_id: ?u32 = null,
session_id: [16]u8,
authority: schema.AgentAuthority = .candidate,
process: ?Evidence = null,
proxy: ProxyState = .{},
screen: ?Evidence = null,
title: Title = .{},
projected: schema.AgentSnapshotEntry,

/// Creates the candidate aggregate for one exact pane generation.
///
/// ```zig
/// var agent = Agent.init(identity);
/// ```
pub fn init(identity: Identity) Agent {
    return .{
        .key = identity.key,
        .process_id = identity.process_id,
        .session_id = identity.session_id,
        .projected = .{
            .pane_id = identity.key.id,
            .pane_generation = identity.key.generation,
            .process_id = identity.process_id,
            .session_id = identity.session_id,
            .provider = .unknown,
            .status = .unknown,
            .source = .screen,
            .authority = .candidate,
            .confidence = 0,
            .sequence = 1,
            .observed_at_ms = 0,
            .expires_at_ms = 0,
        },
    };
}

/// Reports whether this aggregate owns the supplied pane generation.
///
/// ```zig
/// if (agent.matches(key)) {
///     return &agent;
/// }
/// ```
pub fn matches(agent: *const Agent, key: PaneKey) bool {
    return agent.key.id == key.id and agent.key.generation == key.generation;
}

/// Returns the exact pane generation that identifies this aggregate.
///
/// ```zig
/// const key = agent.paneKey();
/// ```
pub fn paneKey(agent: *const Agent) PaneKey {
    return agent.key;
}

/// Applies authoritative foreground-process evidence and replaces evidence
/// belonging to an earlier agent process.
///
/// ```zig
/// if (agent.applyProcess(observation)) {
///     publishProjection();
/// }
/// ```
pub fn applyProcess(agent: *Agent, observation: ProcessObservation) bool {
    if (observation.provider == .unknown or observation.process_id == 0) {
        return false;
    }

    const replaced_process = agent.process != null;

    if (agent.process) |evidence| {
        if (evidence.provider == observation.provider and agent.agent_process_id == observation.process_id) {
            return false;
        }

        agent.screen = null;
        agent.proxy.clear();
    }

    agent.agent_process_id = observation.process_id;
    agent.process = Evidence.fromProcess(&observation);
    agent.authority = if (replaced_process) .active else switch (agent.authority) {
        .candidate, .stale, .exited => .active,
        .active, .obscured, .resumed => agent.authority,
    };

    return true;
}

/// Applies one tracked proxy lifecycle transition and updates agent authority.
///
/// ```zig
/// if (agent.applyProxy(observation)) {
///     publishProjection();
/// }
/// ```
pub fn applyProxy(agent: *Agent, observation: ProxyObservation) bool {
    if (observation.provider == .unknown) {
        return false;
    }

    const established_provider = agent.provider();

    if (established_provider != .unknown and observation.provider != established_provider) {
        return false;
    }

    switch (agent.proxy.apply(observation)) {
        .ignored => return false,
        .activity_refreshed => return true,
        .evidence_replaced => {},
    }

    if (agent.authority == .obscured and
        (observation.phase == .request_started or observation.phase == .response_activity))
    {
        agent.screen = null;
        agent.authority = .resumed;
        return true;
    }

    agent.authority = switch (agent.authority) {
        .candidate, .stale => .active,
        .active, .obscured, .resumed => agent.authority,
        .exited => return false,
    };

    return true;
}

/// Validates and applies one terminal-screen observation against stronger
/// process and proxy identity evidence.
///
/// ```zig
/// if (agent.applyScreen(observation)) {
///     publishProjection();
/// }
/// ```
pub fn applyScreen(agent: *Agent, observation: ScreenObservation) bool {
    const signal = observation.signal;
    const process_provider = if (agent.process) |evidence| evidence.provider else schema.AgentProvider.unknown;

    if (process_provider != .unknown and signal.provider != .unknown and signal.provider != process_provider) {
        return false;
    }

    const known_provider = if (process_provider != .unknown)
        process_provider
    else if (signal.provider != .unknown)
        signal.provider
    else
        agent.provider();

    if (signal.status == .ready and !signal.identity_confirmed and agent.provider() != signal.provider) {
        return false;
    }

    if (known_provider == .unknown) {
        return false;
    }

    if (signal.status == .ready and agent.projected.status == .working and !signal.ready_confirmed) {
        return false;
    }

    agent.screen = Evidence.fromScreen(known_provider, &observation);

    if (signal.status == .blocked) {
        agent.authority = .obscured;
    }

    return true;
}

/// Removes expired heuristic evidence and reports whether the aggregate has no
/// remaining evidence and must leave the registry.
///
/// ```zig
/// if (agent.expire(now_ms)) {
///     removeAgent();
/// }
/// ```
pub fn expire(agent: *Agent, now_ms: i64) bool {
    _ = agent.proxy.clearExpired(now_ms);

    if (agent.screen) |evidence| {
        if (evidence.isExpired(now_ms)) {
            agent.screen = null;
        }
    }

    if (agent.process != null or agent.proxy.currentEvidence() != null or agent.screen != null) {
        return false;
    }

    agent.authority = .stale;
    agent.retire();
    return true;
}

/// Reports and consumes an authoritative foreground-process exit.
///
/// ```zig
/// if (agent.processExited()) {
///     removeAgent();
/// }
/// ```
pub fn processExited(agent: *Agent) bool {
    if (agent.process == null) {
        return false;
    }

    agent.retire();
    return true;
}

/// Clears sensitive pending input before the registry forgets this aggregate.
///
/// ```zig
/// agent.retire();
/// ```
pub fn retire(agent: *Agent) void {
    agent.title.clearSensitive();
}

/// Recomputes the client-facing projection from the aggregate's current
/// evidence and advances title generation when model work begins.
///
/// ```zig
/// const result = agent.reproject(.{ .sequence = 4, .now_ms = now_ms, .can_queue_description = true });
/// ```
pub fn reproject(agent: *Agent, context: ProjectionContext) ProjectionResult {
    const evidence = agent.chooseEvidence(context.now_ms) orelse return .no_evidence;
    const provider_value = agent.projectionProvider(evidence);
    const previous = agent.projected;

    agent.ensurePlaceholder(provider_value);
    agent.projected = .{
        .pane_id = agent.key.id,
        .pane_generation = agent.key.generation,
        .process_id = agent.agent_process_id orelse agent.process_id,
        .session_id = agent.session_id,
        .provider = provider_value,
        .status = evidence.status,
        .source = evidence.source,
        .authority = agent.authority,
        .confidence = evidence.confidence,
        .sequence = context.sequence,
        .observed_at_ms = evidence.observed_at_ms,
        .expires_at_ms = evidence.expires_at_ms,
    };

    const title_changed = agent.advanceTitle(evidence.status, context.can_queue_description);

    if (sameProjection(previous, agent.projected)) {
        agent.projected.sequence = previous.sequence;
        return if (title_changed) .changed else .unchanged;
    }

    return .changed;
}

/// Returns the current immutable client projection, including title storage
/// borrowed from this aggregate.
///
/// ```zig
/// const entry = agent.snapshot();
/// ```
pub fn snapshot(agent: *const Agent) schema.AgentSnapshotEntry {
    var entry = agent.projected;
    entry.session_title = agent.title.slice();
    entry.title_source = agent.title.source;
    entry.title_state = agent.title.state;
    return entry;
}

/// Returns the last projected status for transition detection.
///
/// ```zig
/// const status = agent.projectedStatus();
/// ```
pub fn projectedStatus(agent: *const Agent) schema.AgentStatus {
    return agent.projected.status;
}

/// Captures the first submitted request for this identified agent.
///
/// ```zig
/// _ = agent.observeInput(bytes);
/// ```
pub fn observeInput(agent: *Agent, bytes: []const u8) bool {
    if (agent.title.phase != .waiting_query) {
        return false;
    }

    if (!agent.title.capture.feed(bytes)) {
        return false;
    }

    agent.title.phase = .waiting_work;
    return true;
}

/// Reports whether this aggregate currently owns the sole running description
/// job.
///
/// ```zig
/// if (agent.hasRunningDescription()) {
///     waitForCompletion();
/// }
/// ```
pub fn hasRunningDescription(agent: *const Agent) bool {
    return agent.title.phase == .running;
}

/// Reports whether this aggregate consumes one bounded description slot.
///
/// ```zig
/// if (agent.hasPendingDescription()) {
///     pending += 1;
/// }
/// ```
pub fn hasPendingDescription(agent: *const Agent) bool {
    return agent.title.phase == .queued or agent.title.phase == .running;
}

/// Starts this aggregate's queued description job, or permanently fails an
/// invalid captured query without retrying it.
///
/// ```zig
/// if (agent.startDescriptionJob() == .failed) {
///     publishFailure();
/// }
/// ```
pub fn startDescriptionJob(agent: *Agent) DescriptionJobResult {
    if (agent.title.phase != .queued) {
        return .not_queued;
    }

    var normalized: [description.max_query_bytes]u8 = undefined;
    const query = description.normalizeQuery(agent.title.capture.raw(), &normalized) catch {
        agent.title.phase = .failed;
        agent.title.state = .failed;
        agent.title.clearSensitive();
        return .failed;
    };

    var job: description.Job = .{
        .pane = agent.key,
        .session_id = agent.session_id,
        .provider = agent.provider(),
        .query_len = @intCast(query.len),
    };
    @memcpy(job.query[0..query.len], query);
    std.crypto.secureZero(u8, &normalized);
    agent.title.clearSensitive();
    agent.title.phase = .running;
    return .{ .started = job };
}

/// Applies a generated title only to the session and running job that launched
/// it.
///
/// ```zig
/// _ = agent.finishDescription(&result);
/// ```
pub fn finishDescription(agent: *Agent, result: *const description.Result) bool {
    if (!agent.matches(result.pane) or agent.title.phase != .running or
        !std.mem.eql(u8, &agent.session_id, &result.session_id))
    {
        return false;
    }

    if (result.status == .success) {
        const value = result.titleSlice();

        if (value.len == 0 or value.len > agent.title.bytes.len or !validTitle(value)) {
            agent.title.phase = .failed;
            agent.title.state = .failed;
        } else {
            @memcpy(agent.title.bytes[0..value.len], value);
            agent.title.len = @intCast(value.len);
            agent.title.source = .generated;
            agent.title.state = .ready;
            agent.title.phase = .finished;
        }
    } else {
        agent.title.phase = .failed;
        agent.title.state = .failed;
    }

    return true;
}

/// Replaces any generated or pending title with a validated manual title.
///
/// ```zig
/// _ = try agent.setManualTitle("Investigate proxy lifecycle");
/// ```
pub fn setManualTitle(agent: *Agent, value: []const u8) !void {
    if (!validTitle(value) or value.len > agent.title.bytes.len) {
        return error.InvalidAgentTitle;
    }

    agent.title.clearSensitive();
    @memcpy(agent.title.bytes[0..value.len], value);
    agent.title.len = @intCast(value.len);
    agent.title.source = .manual;
    agent.title.state = .ready;
    agent.title.phase = .finished;
}

fn provider(agent: *const Agent) schema.AgentProvider {
    if (agent.process) |evidence| {
        return evidence.provider;
    }

    if (agent.proxy.currentEvidence()) |evidence| {
        if (evidence.provider != .unknown) {
            return evidence.provider;
        }
    }

    if (agent.screen) |evidence| {
        return evidence.provider;
    }

    return .unknown;
}

fn chooseEvidence(agent: *const Agent, now_ms: i64) ?Evidence {
    const process = agent.process;
    const screen = if (agent.screen) |value|
        if (!value.isExpired(now_ms)) value else null
    else
        null;
    const proxy = if (agent.proxy.currentEvidence()) |value|
        if (!value.isExpired(now_ms)) value else null
    else
        null;

    // Visible permission and work states outrank network activity. A proxy
    // working state still outranks an older ready prompt.
    if (screen) |value| {
        if (value.status == .blocked) {
            return value;
        }
    }

    if (screen) |value| {
        if (value.status == .working) {
            return value;
        }
    }

    if (proxy) |proxy_work| {
        if (proxy_work.status == .working) {
            // A newer confirmed prompt repairs a dropped proxy completion.
            if (screen) |screen_ready| {
                if (screen_ready.status == .ready and screen_ready.observed_at_ms > proxy_work.observed_at_ms) {
                    return screen_ready;
                }
            }

            return proxy_work;
        }
    }

    if (screen) |value| {
        if (value.status == .ready) {
            return value;
        }
    }

    if (proxy) |value| {
        return value;
    }

    if (screen) |value| {
        return value;
    }

    return process;
}

fn projectionProvider(agent: *const Agent, evidence: Evidence) schema.AgentProvider {
    if (agent.process) |process| {
        return process.provider;
    }

    if (evidence.provider != .unknown) {
        return evidence.provider;
    }

    if (agent.proxy.currentEvidence()) |proxy| {
        return proxy.provider;
    }

    if (agent.screen) |screen| {
        return screen.provider;
    }

    return .unknown;
}

fn ensurePlaceholder(agent: *Agent, provider_value: schema.AgentProvider) void {
    if (agent.title.source != .telar) {
        return;
    }

    const placeholder = switch (provider_value) {
        .codex => "New Codex session",
        .claude => "New Claude Code session",
        .unknown => "New agent session",
    };

    if (std.mem.eql(u8, agent.title.slice(), placeholder)) {
        return;
    }

    @memcpy(agent.title.bytes[0..placeholder.len], placeholder);
    agent.title.len = @intCast(placeholder.len);
}

fn advanceTitle(agent: *Agent, status: schema.AgentStatus, can_queue: bool) bool {
    if (agent.title.phase != .waiting_work or status != .working) {
        return false;
    }

    if (!can_queue) {
        agent.title.phase = .failed;
        agent.title.state = .failed;
        agent.title.clearSensitive();
    } else {
        agent.title.phase = .queued;
        agent.title.state = .pending;
    }

    return true;
}

fn validTitle(value: []const u8) bool {
    if (value.len == 0 or value.len > schema.max_agent_session_title_bytes or !std.unicode.utf8ValidateSlice(value)) {
        return false;
    }

    for (value) |byte| {
        if (byte < 0x20 or byte == 0x7f) {
            return false;
        }
    }

    return true;
}

fn sameProjection(left_value: schema.AgentSnapshotEntry, right_value: schema.AgentSnapshotEntry) bool {
    var left = left_value;
    var right = right_value;
    left.sequence = 0;
    right.sequence = 0;
    return std.meta.eql(left, right);
}

fn testIdentity() !Identity {
    return .{
        .key = .{ .id = try schema.id.pane(7), .generation = 3 },
        .process_id = 42,
        .session_id = .{0xa5} ** 16,
    };
}

test "agent rejects an untracked proxy response" {
    var agent = Agent.init(try testIdentity());
    const exchange: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };

    try std.testing.expect(!agent.applyProxy(.{
        .identity = try testIdentity(),
        .provider = .claude,
        .phase = .response_activity,
        .exchange = exchange,
        .observed_at_ms = 100,
    }));
    try std.testing.expect(agent.proxy.currentEvidence() == null);
    try std.testing.expectEqual(schema.AgentAuthority.candidate, agent.authority);
}

test "agent applies a tracked proxy lifecycle" {
    const identity = try testIdentity();
    var agent = Agent.init(identity);
    const exchange: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };

    try std.testing.expect(agent.applyProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .request_started,
        .exchange = exchange,
        .observed_at_ms = 100,
    }));
    try std.testing.expectEqual(schema.AgentAuthority.active, agent.authority);

    try std.testing.expect(agent.applyProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .response_finished,
        .exchange = exchange,
        .observed_at_ms = 200,
    }));

    const evidence = agent.proxy.currentEvidence().?;
    try std.testing.expectEqual(schema.AgentProvider.claude, evidence.provider);
    try std.testing.expectEqual(schema.AgentStatus.working, evidence.status);
    try std.testing.expectEqual(schema.AgentSource.proxy_tls, evidence.source);
    try std.testing.expectEqual(@as(i64, 200), evidence.observed_at_ms);
}

test "agent applies semantic completion without changing its authority" {
    const identity = try testIdentity();
    var agent = Agent.init(identity);
    const exchange: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };

    try std.testing.expect(agent.applyProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .request_started,
        .exchange = exchange,
        .observed_at_ms = 100,
    }));
    try std.testing.expect(agent.applyProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .provider_turn_completed,
        .exchange = exchange,
        .observed_at_ms = 200,
    }));

    const evidence = agent.proxy.currentEvidence().?;
    try std.testing.expectEqual(schema.AgentStatus.ready, evidence.status);
    try std.testing.expectEqual(schema.AgentAuthority.active, agent.authority);
}

test "agent rejects completion from a contradictory provider" {
    const identity = try testIdentity();
    var agent = Agent.init(identity);
    const exchange: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };

    _ = agent.applyProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .request_started,
        .exchange = exchange,
        .observed_at_ms = 100,
    });
    try std.testing.expect(!agent.applyProxy(.{
        .identity = identity,
        .provider = .codex,
        .phase = .provider_turn_completed,
        .exchange = exchange,
        .observed_at_ms = 200,
    }));
    var evidence = agent.proxy.currentEvidence().?;
    try std.testing.expectEqual(schema.AgentProvider.claude, evidence.provider);
    try std.testing.expectEqual(schema.AgentStatus.working, evidence.status);
    try std.testing.expectEqual(@as(i64, 100), evidence.observed_at_ms);

    try std.testing.expect(agent.applyProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .provider_turn_completed,
        .exchange = exchange,
        .observed_at_ms = 300,
    }));
    evidence = agent.proxy.currentEvidence().?;
    try std.testing.expectEqual(schema.AgentProvider.claude, evidence.provider);
    try std.testing.expectEqual(schema.AgentStatus.ready, evidence.status);
    try std.testing.expectEqual(@as(i64, 300), evidence.observed_at_ms);
}

test "semantic completion does not clear stronger blocked screen evidence" {
    const identity = try testIdentity();
    var agent = Agent.init(identity);
    const exchange: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };

    _ = agent.applyProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .request_started,
        .exchange = exchange,
        .observed_at_ms = 100,
    });
    agent.authority = .obscured;
    agent.screen = .{
        .provider = .claude,
        .status = .blocked,
        .source = .screen,
        .confidence = 98,
        .observed_at_ms = 150,
        .expires_at_ms = 150 + types.settled_expiry_ms,
    };

    try std.testing.expect(agent.applyProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .provider_turn_completed,
        .exchange = exchange,
        .observed_at_ms = 200,
    }));
    try std.testing.expectEqual(schema.AgentAuthority.obscured, agent.authority);
    try std.testing.expect(agent.screen != null);
    try std.testing.expectEqual(schema.AgentStatus.blocked, agent.chooseEvidence(200).?.status);
}

test "agent coalesces frequent proxy activity" {
    const identity = try testIdentity();
    var agent = Agent.init(identity);
    const exchange: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };

    try std.testing.expect(agent.applyProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .request_started,
        .exchange = exchange,
        .observed_at_ms = 100,
    }));
    try std.testing.expect(!agent.applyProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .response_activity,
        .exchange = exchange,
        .observed_at_ms = 100 + types.activity_refresh_ms - 1,
    }));
    try std.testing.expectEqual(@as(i64, 100), agent.proxy.currentEvidence().?.observed_at_ms);

    const refreshed_at = 100 + types.activity_refresh_ms;
    try std.testing.expect(agent.applyProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .response_activity,
        .exchange = exchange,
        .observed_at_ms = refreshed_at,
    }));
    try std.testing.expectEqual(refreshed_at, agent.proxy.currentEvidence().?.observed_at_ms);
    try std.testing.expectEqual(refreshed_at + types.working_expiry_ms, agent.proxy.currentEvidence().?.expires_at_ms);
}

test "new proxy work resumes an obscured agent" {
    const identity = try testIdentity();
    var agent = Agent.init(identity);
    const exchange: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };

    agent.authority = .obscured;
    agent.screen = .{
        .provider = .claude,
        .status = .blocked,
        .source = .screen,
        .confidence = 88,
        .observed_at_ms = 50,
        .expires_at_ms = types.settled_expiry_ms,
    };

    try std.testing.expect(agent.applyProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .request_started,
        .exchange = exchange,
        .observed_at_ms = 100,
    }));
    try std.testing.expectEqual(schema.AgentAuthority.resumed, agent.authority);
    try std.testing.expect(agent.screen == null);
}
