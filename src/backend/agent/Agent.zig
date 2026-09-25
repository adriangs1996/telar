//! One runtime-owned agent aggregate.
//!
//! Every process, proxy, screen, title, authority, and projection mutation for
//! one pane generation crosses this type.

const core = @import("telar-core");
const Job = @import("Job.zig");
const PaneKey = @import("../pane/PaneKey.zig");
const Evidence = @import("Evidence.zig");
const ProxyState = @import("ProxyState.zig");
const Title = @import("Title.zig");
const SessionReference = @import("SessionReference.zig");
const Identity = @import("Identity.zig");
const ProcessObservation = @import("ProcessObservation.zig");
const ProxyObservation = @import("ProxyObservation.zig");
const providers = @import("providers/providers.zig");
const ReportObservation = @import("ReportObservation.zig");
const ScreenObservation = @import("ScreenObservation.zig");
const std = @import("std");
const description = @import("description.zig");
const Result = @import("Result.zig");
const DescriptionFinished = @import("DescriptionFinished.zig");
const SessionTitle = @import("SessionTitle.zig");
const types = @import("types.zig");
const ProxyExchange = @import("ProxyExchange.zig");
const EventLine = @import("EventLine.zig");

const Agent = @This();

pub const ProjectionContext = @import("ProjectionContext.zig");

pub const ProjectionResult = enum {
    no_evidence,
    unchanged,
    changed,
};

pub const DescriptionJobResult = union(enum) {
    not_queued,
    failed,
    started: Job,
};

pub const TitlePhase = enum {
    waiting_query,
    waiting_work,
    queued,
    running,
    finished,
    failed,
};

key: PaneKey,
process_id: u32,
agent_process_id: ?u32 = null,
session_id: [16]u8,
authority: core.AgentAuthority = .candidate,
process: ?Evidence = null,
proxy: ProxyState = .{},
screen: ?Evidence = null,
/// Official lifecycle report; outranks every other evidence while valid.
report: ?Evidence = null,
report_settling: bool = false,
/// Reason and event line of `report`; consulted only while it decides.
report_detail: ReportDetail = .{},
/// The line the projection shows; recomputed on every reprojection.
event: EventLine = .{},
/// Wall-clock time of the last projected status change; 0 until the first
/// projection.
status_changed_at_ms: i64 = 0,
title: Title = .{},
/// False from a completed turn until a client acknowledges it; the projection
/// reports `done` instead of `ready` while unseen.
seen: bool = true,
session_reference: ?SessionReference = null,
projected: core.AgentSnapshotEntry,

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
pub fn matches(self: *const Agent, key: PaneKey) bool {
    return self.key.id == key.id and self.key.generation == key.generation;
}

/// Returns the exact pane generation that identifies this aggregate.
///
/// ```zig
/// const key = agent.paneKey();
/// ```
pub fn paneKey(self: *const Agent) PaneKey {
    return self.key;
}

/// Applies authoritative foreground-process evidence and replaces evidence
/// belonging to an earlier agent process.
///
/// ```zig
/// if (agent.applyProcess(observation)) {
///     publishProjection();
/// }
/// ```
pub fn applyProcess(self: *Agent, observation: ProcessObservation) bool {
    if (observation.provider == .unknown or observation.process_id == 0) {
        return false;
    }

    const replaced_process = self.process != null;

    if (self.process) |evidence| {
        if (evidence.provider == observation.provider and self.agent_process_id == observation.process_id) {
            return false;
        }

        self.screen = null;
        self.report = null;
        self.proxy.clear();
    }

    self.agent_process_id = observation.process_id;
    self.process = Evidence.fromProcess(&observation);
    self.authority = if (replaced_process) .active else switch (self.authority) {
        .candidate, .stale, .exited => .active,
        .active, .obscured, .resumed => self.authority,
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
pub fn applyProxy(self: *Agent, observation: ProxyObservation) bool {
    if (observation.dialect == .unknown) {
        return false;
    }

    // The proxy names the API dialect it saw on the wire, which implies an
    // agent identity only while no process has claimed the pane. A
    // process-backed agent may talk to any host, so its exchanges count
    // regardless of dialect; only proxy- or screen-derived identity rejects a
    // foreign one.
    const established_provider = self.provider();

    if (self.process == null and established_provider != .unknown and observation.impliedProvider() != established_provider) {
        return false;
    }

    switch (self.proxy.apply(observation)) {
        .ignored => return false,
        .activity_refreshed => return true,
        .evidence_replaced => {},
    }

    if (providers.of(established_provider).ready_prompt_settles_report and observation.phase == .request_started) {
        if (self.screen) |screen| {
            if (screen.status == .ready and screen.observed_at_ms <= observation.observed_at_ms) {
                self.screen = null;
            }
        }
    }

    if (self.authority == .obscured and
        (observation.phase == .request_started or observation.phase == .response_activity))
    {
        self.screen = null;
        self.authority = .resumed;
        return true;
    }

    self.authority = switch (self.authority) {
        .candidate, .stale => .active,
        .active, .obscured, .resumed => self.authority,
        .exited => return false,
    };

    return true;
}

/// Applies one official lifecycle report. `exited` withdraws the report so
/// weaker evidence decides again; every other state becomes the ranking
/// evidence until it expires.
///
/// ```zig
/// if (agent.applyReport(observation)) {
///     publishProjection();
/// }
/// ```
pub fn applyReport(self: *Agent, observation: ReportObservation) bool {
    if (observation.state == .exited) {
        if (self.report == null) {
            return false;
        }

        self.report = null;
        self.report_detail = .{};
        return true;
    }

    self.report_settling = observation.state == .settling;
    self.report_detail = .{
        .blocked_reason = observation.blocked_reason,
        .event = EventLine.init(observation.event),
    };
    if (providers.of(self.provider()).ready_prompt_settles_report and observation.state == .working) {
        // A prompt from before this tool or turn cannot become completion
        // evidence later, when the report expires.
        if (self.screen) |screen| {
            if (screen.status == .ready) {
                self.screen = null;
            }
        }
    }

    self.report = Evidence.fromReport(self.provider(), &observation);
    self.authority = switch (self.authority) {
        .candidate, .stale, .obscured => .active,
        .active, .resumed => self.authority,
        .exited => .active,
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
pub fn applyScreen(self: *Agent, observation: ScreenObservation) bool {
    const signal = observation.signal;
    const process_provider = if (self.process) |evidence| evidence.provider else core.AgentProvider.unknown;

    if (process_provider != .unknown and signal.provider != .unknown and signal.provider != process_provider) {
        return false;
    }

    const known_provider = if (process_provider != .unknown)
        process_provider
    else if (signal.provider != .unknown)
        signal.provider
    else
        self.provider();

    if (signal.status == .ready and !signal.identity_confirmed and self.provider() != signal.provider) {
        return false;
    }

    if (known_provider == .unknown) {
        return false;
    }

    if (signal.status == .ready and self.projected.status == .working and !signal.ready_confirmed) {
        return false;
    }

    if (providers.of(known_provider).ready_prompt_settles_report) {
        if (self.screen) |screen| {
            if (screenOrder(observation, screen) == .lt) {
                return false;
            }
        }

        if (self.report) |report| {
            if (screenOrder(observation, report) != .gt) {
                return false;
            }

            if (signal.status == .ready) {
                if (!signal.ready_confirmed or (report.status == .working and !self.report_settling and !report.isExpired(observation.observed_at_ms))) {
                    return false;
                }

                self.report = null;
            } else if (report.status == .ready) {
                // SessionStart and Interrupt describe a moment, not a
                // permanent veto of later visible activity.
                self.report = null;
            }
        }
    }

    self.screen = Evidence.fromScreen(known_provider, &observation);

    if (signal.status == .blocked) {
        self.authority = .obscured;
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
pub fn expire(self: *Agent, now_ms: i64) bool {
    _ = self.proxy.clearExpired(now_ms);

    if (self.screen) |evidence| {
        if (evidence.isExpired(now_ms)) {
            self.screen = null;
        }
    }

    if (self.report) |evidence| {
        if (evidence.isExpired(now_ms)) {
            self.report = null;
        }
    }

    if (self.process != null or self.proxy.currentEvidence() != null or self.screen != null or self.report != null) {
        return false;
    }

    self.authority = .stale;
    self.retire();
    return true;
}

/// Reports and consumes an authoritative foreground-process exit.
///
/// ```zig
/// if (agent.processExited()) {
///     removeAgent();
/// }
/// ```
pub fn processExited(self: *Agent) bool {
    if (self.process == null) {
        return false;
    }

    self.retire();
    return true;
}

/// Clears sensitive pending input before the registry forgets this aggregate.
///
/// ```zig
/// agent.retire();
/// ```
pub fn retire(self: *Agent) void {
    self.title.clearSensitive();
}

/// Recomputes the client-facing projection from the aggregate's current
/// evidence and advances title generation when model work begins.
///
/// ```zig
/// const result = agent.reproject(.{ .sequence = 4, .now_ms = now_ms, .can_queue_description = true });
/// ```
pub fn reproject(self: *Agent, context: ProjectionContext) ProjectionResult {
    const evidence = self.chooseEvidence(context.now_ms) orelse return .no_evidence;
    const provider_value = self.projectionProvider(evidence);
    const previous = self.projected;

    self.ensurePlaceholder();
    self.projected = .{
        .pane_id = self.key.id,
        .pane_generation = self.key.generation,
        .process_id = self.agent_process_id orelse self.process_id,
        .session_id = self.session_id,
        .provider = provider_value,
        .status = self.visibleStatus(previous.status, evidence.status),
        .source = evidence.source,
        .authority = self.authority,
        .confidence = evidence.confidence,
        .sequence = context.sequence,
        .observed_at_ms = evidence.observed_at_ms,
        .expires_at_ms = evidence.expires_at_ms,
    };

    self.projected.blocked_reason = self.blockedReason(evidence);
    if (self.projected.status != previous.status or self.status_changed_at_ms == 0) {
        self.status_changed_at_ms = context.now_ms;
    }

    const title_changed = self.advanceTitle(evidence.status, context.can_queue_description);
    const event_changed = self.refreshEvent(evidence);

    if (sameProjection(previous, self.projected)) {
        self.projected.sequence = previous.sequence;
        return if (title_changed or event_changed) .changed else .unchanged;
    }

    return .changed;
}

/// Returns the current immutable client projection, including title and
/// event storage borrowed from this aggregate. `now_ms` measures how long
/// the projected status has held; the age is never part of the revision.
///
/// ```zig
/// const entry = agent.snapshot(now_ms);
/// ```
pub fn snapshot(self: *const Agent, now_ms: i64) core.AgentSnapshotEntry {
    var entry = self.projected;
    entry.session_title = self.title.slice();
    entry.title_source = self.title.source;
    entry.title_state = self.title.state;
    entry.last_event = self.event.slice();
    entry.status_age_s = self.statusAgeSeconds(now_ms);
    return entry;
}

/// Seconds the projected status has held at `now_ms`, saturating instead of
/// wrapping when the clock moves backwards or the agent outlives `u32`.
///
/// ```zig
/// const age = agent.statusAgeSeconds(now_ms);
/// ```
pub fn statusAgeSeconds(self: *const Agent, now_ms: i64) u32 {
    if (self.status_changed_at_ms == 0 or now_ms <= self.status_changed_at_ms) {
        return 0;
    }

    return @intCast(@min(@divFloor(now_ms - self.status_changed_at_ms, 1000), std.math.maxInt(u32)));
}

/// Returns the last projected status for transition detection.
///
/// ```zig
/// const status = agent.projectedStatus();
/// ```
pub fn projectedStatus(self: *const Agent) core.AgentStatus {
    return self.projected.status;
}

/// Stores the agent's own session reference. A later report replaces an
/// earlier one; an identical report changes nothing.
///
/// ```zig
/// if (agent.applySessionReference(reference)) persist();
/// ```
pub fn applySessionReference(self: *Agent, reference: SessionReference) bool {
    if (self.session_reference) |existing| {
        if (std.mem.eql(u8, existing.slice(), reference.slice())) {
            return false;
        }
    }

    self.session_reference = reference;
    return true;
}

/// Marks an unseen completion as seen. The caller reprojects so `done`
/// becomes `ready`.
///
/// ```zig
/// if (agent.acknowledge()) {
///     publishProjection();
/// }
/// ```
pub fn acknowledge(self: *Agent) bool {
    if (self.seen) {
        return false;
    }

    self.seen = true;
    return true;
}

/// Captures the first submitted request for this identified agent.
///
/// ```zig
/// _ = agent.observeInput(bytes);
/// ```
pub fn observeInput(self: *Agent, bytes: []const u8) bool {
    if (self.title.phase != .waiting_query) {
        return false;
    }

    if (!self.title.capture.feed(bytes)) {
        return false;
    }

    self.title.phase = .waiting_work;
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
pub fn hasRunningDescription(self: *const Agent) bool {
    return self.title.phase == .running;
}

/// Reports whether this aggregate consumes one bounded description slot.
///
/// ```zig
/// if (agent.hasPendingDescription()) {
///     pending += 1;
/// }
/// ```
pub fn hasPendingDescription(self: *const Agent) bool {
    return self.title.phase == .queued or self.title.phase == .running;
}

/// Starts this aggregate's queued description job, or permanently fails an
/// invalid captured query without retrying it.
///
/// ```zig
/// if (agent.startDescriptionJob() == .failed) {
///     publishFailure();
/// }
/// ```
pub fn startDescriptionJob(self: *Agent) DescriptionJobResult {
    if (self.title.phase != .queued) {
        return .not_queued;
    }

    var normalized: [description.max_query_bytes]u8 = undefined;
    const query = description.normalizeQuery(self.title.capture.raw(), &normalized) catch {
        self.title.phase = .failed;
        self.title.state = .failed;
        self.title.clearSensitive();
        return .failed;
    };

    var job: Job = .{
        .pane = self.key,
        .session_id = self.session_id,
        .provider = self.provider(),
        .query_len = @intCast(query.len),
    };
    @memcpy(job.query[0..query.len], query);
    std.crypto.secureZero(u8, &normalized);
    self.title.clearSensitive();
    self.title.phase = .running;
    return .{ .started = job };
}

/// Applies a generated title only to the session and running job that launched
/// it, then returns the aggregate-validated title projection for persistence.
///
/// ```zig
/// const finished = agent.finishDescription(&result) orelse return;
/// ```
pub fn finishDescription(self: *Agent, result: *const Result) ?DescriptionFinished {
    if (!self.matches(result.pane) or self.title.phase != .running or
        !std.mem.eql(u8, &self.session_id, &result.session_id))
    {
        return null;
    }

    if (result.status == .success) {
        const value = result.titleSlice();

        if (value.len == 0 or value.len > self.title.bytes.len or !validTitle(value)) {
            self.title.phase = .failed;
            self.title.state = .failed;
        } else {
            @memcpy(self.title.bytes[0..value.len], value);
            self.title.len = @intCast(value.len);
            self.title.source = .generated;
            self.title.state = .ready;
            self.title.phase = .finished;
        }
    } else {
        self.title.phase = .failed;
        self.title.state = .failed;
    }

    std.debug.assert(self.title.state == .ready or self.title.state == .failed);
    var finished: DescriptionFinished = .{
        .pane = self.key,
        .session_id = self.session_id,
        .source = if (self.title.state == .ready) self.title.source else .telar,
        .state = self.title.state,
    };

    if (self.title.state == .ready) {
        finished.title_len = self.title.len;
        @memcpy(finished.title[0..self.title.len], self.title.slice());
    }

    return finished;
}

/// Replaces any generated or pending title with a validated manual title.
///
/// ```zig
/// _ = try agent.setManualTitle("Investigate proxy lifecycle");
/// ```
pub fn setManualTitle(self: *Agent, value: []const u8) !void {
    if (!validTitle(value)) {
        return error.InvalidAgentTitle;
    }

    self.applyReadyTitle(value, .manual);
}

/// Applies the name the agent's own session carries, as reported by its
/// hooks. An empty value clears an earlier agent title back to the
/// placeholder; the agent never clears a manual or generated title. Returns
/// whether the title changed.
///
/// ```zig
/// if (try agent.reportTitle("Fix proxy")) publish();
/// ```
pub fn reportTitle(self: *Agent, value: []const u8) !bool {
    if (value.len == 0) {
        if (self.title.source != .agent) {
            return false;
        }

        self.title = .{ .phase = .finished };
        return true;
    }

    if (!validTitle(value)) {
        return error.InvalidAgentTitle;
    }

    if (self.title.source == .agent and std.mem.eql(u8, self.title.slice(), value)) {
        return false;
    }

    self.applyReadyTitle(value, .agent);
    return true;
}

/// Hands a checkpointed title back to the agent that resumed the session. The
/// title is final: no description job is queued for the first prompt.
///
/// ```zig
/// agent.restoreTitle(title);
/// ```
pub fn restoreTitle(self: *Agent, title: SessionTitle) void {
    self.applyReadyTitle(title.slice(), title.source);
}

/// Returns the title worth checkpointing: a ready generated, manual or agent
/// one.
///
/// ```zig
/// const title = agent.durableTitle() orelse return;
/// ```
pub fn durableTitle(self: *const Agent) ?SessionTitle {
    if (self.title.state != .ready) {
        return null;
    }

    return SessionTitle.init(self.title.slice(), self.title.source) catch null;
}

fn applyReadyTitle(self: *Agent, value: []const u8, source: core.AgentTitleSource) void {
    std.debug.assert(validTitle(value));
    self.title.clearSensitive();
    @memcpy(self.title.bytes[0..value.len], value);
    self.title.len = @intCast(value.len);
    self.title.source = source;
    self.title.state = .ready;
    self.title.phase = .finished;
}

// The hook names the reason when it has one. Without it, a response that
// closed on a tool request while nothing is in flight is a permission
// prompt; the remaining blocked states carry no evidence about their cause.
fn blockedReason(self: *const Agent, evidence: Evidence) core.AgentBlockedReason {
    if (self.projected.status != .blocked) {
        return .none;
    }

    if (evidence.source == .lifecycle_report and self.report_detail.blocked_reason != .none) {
        return self.report_detail.blocked_reason;
    }

    if (self.proxy.awaitingToolResult()) {
        return .permission;
    }

    return .other;
}

// The event line follows the report that decides the projection; any other
// evidence carries no line. Returns whether the shown line changed.
fn refreshEvent(self: *Agent, evidence: Evidence) bool {
    const next: EventLine = if (evidence.source == .lifecycle_report) self.report_detail.event else .{};
    if (self.event.eql(&next)) {
        return false;
    }

    self.event = next;
    return true;
}

fn provider(self: *const Agent) core.AgentProvider {
    if (self.process) |evidence| {
        return evidence.provider;
    }

    if (self.proxy.currentEvidence()) |evidence| {
        if (evidence.provider != .unknown) {
            return evidence.provider;
        }
    }

    if (self.screen) |evidence| {
        return evidence.provider;
    }

    return .unknown;
}

fn chooseEvidence(self: *const Agent, now_ms: i64) ?Evidence {
    const process = self.process;
    const screen = if (self.screen) |value|
        if (!value.isExpired(now_ms)) value else null
    else
        null;
    const proxy = if (self.proxy.currentEvidence()) |value|
        if (!value.isExpired(now_ms)) value else null
    else
        null;

    // An official lifecycle report outranks everything the runtime infers.
    if (self.report) |value| {
        if (!value.isExpired(now_ms)) {
            return value;
        }
    }

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
        if (value.status == .ready and process != null and providers.of(process.?.provider).completion_requires_agent_signal) {
            // A model response can be followed by local tools or another
            // model request. The agent must confirm its own turn completion.
            var working = value;
            working.status = .working;
            working.expires_at_ms = value.observed_at_ms + types.working_expiry_ms;
            if (working.isExpired(now_ms)) {
                var unknown = process.?;
                unknown.status = .unknown;
                return unknown;
            }

            return working;
        }

        return value;
    }

    if (screen) |value| {
        return value;
    }

    if (process) |value| {
        if (providers.of(value.provider).completion_requires_agent_signal) {
            var unknown = value;
            unknown.status = .unknown;
            return unknown;
        }
    }

    return process;
}

fn screenOrder(observation: ScreenObservation, evidence: Evidence) std.math.Order {
    if (observation.observed_at_ns) |observed| {
        if (evidence.observed_at_ns) |previous| {
            return std.math.order(observed, previous);
        }
    }

    return std.math.order(observation.observed_at_ms, evidence.observed_at_ms);
}

/// A turn that finished while the previous projection was `working` stays
/// `done` until acknowledged. Any other evidence status ends the unseen
/// window so the next completion is reported again.
fn visibleStatus(self: *Agent, previous: core.AgentStatus, current: core.AgentStatus) core.AgentStatus {
    if (current != .ready) {
        self.seen = true;
        return current;
    }

    if (previous == .working) {
        self.seen = false;
    }

    return if (self.seen) .ready else .done;
}

fn projectionProvider(self: *const Agent, evidence: Evidence) core.AgentProvider {
    if (self.process) |process| {
        return process.provider;
    }

    if (evidence.provider != .unknown) {
        return evidence.provider;
    }

    if (self.proxy.currentEvidence()) |proxy| {
        return proxy.provider;
    }

    if (self.screen) |screen| {
        return screen.provider;
    }

    return .unknown;
}

// The aggregate carries the generic placeholder only; delivery replaces it
// with the manifest's own wording, next to the provider name it also adds.
fn ensurePlaceholder(self: *Agent) void {
    if (self.title.source != .telar) {
        return;
    }

    const placeholder = core.generic_placeholder;

    if (std.mem.eql(u8, self.title.slice(), placeholder)) {
        return;
    }

    @memcpy(self.title.bytes[0..placeholder.len], placeholder);
    self.title.len = @intCast(placeholder.len);
}

fn advanceTitle(self: *Agent, status: core.AgentStatus, can_queue: bool) bool {
    if (self.title.phase != .waiting_work or status != .working) {
        return false;
    }

    if (!can_queue) {
        self.title.phase = .failed;
        self.title.state = .failed;
        self.title.clearSensitive();
    } else {
        self.title.phase = .queued;
        self.title.state = .pending;
    }

    return true;
}

fn validTitle(value: []const u8) bool {
    core.validateSessionTitle(value) catch return false;
    return true;
}

fn sameProjection(left_value: core.AgentSnapshotEntry, right_value: core.AgentSnapshotEntry) bool {
    var left = left_value;
    var right = right_value;
    left.sequence = 0;
    right.sequence = 0;
    return std.meta.eql(left, right);
}

fn testIdentity() !Identity {
    return .{
        .key = .{ .id = try core.pane(7), .generation = 3 },
        .process_id = 42,
        .session_id = .{0xa5} ** 16,
    };
}

test "agent rejects an untracked proxy response" {
    var agent = init(try testIdentity());
    const exchange: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };

    try std.testing.expect(!agent.applyProxy(.{
        .identity = try testIdentity(),
        .dialect = .anthropic_messages,
        .phase = .response_activity,
        .exchange = exchange,
        .observed_at_ms = 100,
    }));
    try std.testing.expect(agent.proxy.currentEvidence() == null);
    try std.testing.expectEqual(core.AgentAuthority.candidate, agent.authority);
}

test "agent applies a tracked proxy lifecycle" {
    const identity = try testIdentity();
    var agent = init(identity);
    const exchange: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };

    try std.testing.expect(agent.applyProxy(.{
        .identity = identity,
        .dialect = .anthropic_messages,
        .phase = .request_started,
        .exchange = exchange,
        .observed_at_ms = 100,
    }));
    try std.testing.expectEqual(core.AgentAuthority.active, agent.authority);

    try std.testing.expect(agent.applyProxy(.{
        .identity = identity,
        .dialect = .anthropic_messages,
        .phase = .response_finished,
        .exchange = exchange,
        .observed_at_ms = 200,
    }));

    const evidence = agent.proxy.currentEvidence().?;
    try std.testing.expectEqual(core.AgentProvider.claude, evidence.provider);
    try std.testing.expectEqual(core.AgentStatus.working, evidence.status);
    try std.testing.expectEqual(core.AgentSource.proxy_tls, evidence.source);
    try std.testing.expectEqual(@as(i64, 200), evidence.observed_at_ms);
}

test "agent applies semantic completion without changing its authority" {
    const identity = try testIdentity();
    var agent = init(identity);
    const exchange: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };

    try std.testing.expect(agent.applyProxy(.{
        .identity = identity,
        .dialect = .anthropic_messages,
        .phase = .request_started,
        .exchange = exchange,
        .observed_at_ms = 100,
    }));
    try std.testing.expect(agent.applyProxy(.{
        .identity = identity,
        .dialect = .anthropic_messages,
        .phase = .provider_turn_completed,
        .exchange = exchange,
        .observed_at_ms = 200,
    }));

    const evidence = agent.proxy.currentEvidence().?;
    try std.testing.expectEqual(core.AgentStatus.ready, evidence.status);
    try std.testing.expectEqual(core.AgentAuthority.active, agent.authority);
}

test "agent rejects completion from a contradictory provider" {
    const identity = try testIdentity();
    var agent = init(identity);
    const exchange: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };

    _ = agent.applyProxy(.{
        .identity = identity,
        .dialect = .anthropic_messages,
        .phase = .request_started,
        .exchange = exchange,
        .observed_at_ms = 100,
    });
    try std.testing.expect(!agent.applyProxy(.{
        .identity = identity,
        .dialect = .openai_responses,
        .phase = .provider_turn_completed,
        .exchange = exchange,
        .observed_at_ms = 200,
    }));
    var evidence = agent.proxy.currentEvidence().?;
    try std.testing.expectEqual(core.AgentProvider.claude, evidence.provider);
    try std.testing.expectEqual(core.AgentStatus.working, evidence.status);
    try std.testing.expectEqual(@as(i64, 100), evidence.observed_at_ms);

    try std.testing.expect(agent.applyProxy(.{
        .identity = identity,
        .dialect = .anthropic_messages,
        .phase = .provider_turn_completed,
        .exchange = exchange,
        .observed_at_ms = 300,
    }));
    evidence = agent.proxy.currentEvidence().?;
    try std.testing.expectEqual(core.AgentProvider.claude, evidence.provider);
    try std.testing.expectEqual(core.AgentStatus.ready, evidence.status);
    try std.testing.expectEqual(@as(i64, 300), evidence.observed_at_ms);
}

test "a process-backed agent accepts exchanges with any provider family" {
    const identity = try testIdentity();
    var agent = init(identity);
    const exchange: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };

    try std.testing.expect(agent.applyProcess(.{
        .identity = identity,
        .provider = .pi,
        .process_id = 42,
        .observed_at_ms = 50,
    }));

    // Pi talks to Anthropic here; the wire family must not reject the exchange.
    try std.testing.expect(agent.applyProxy(.{
        .identity = identity,
        .dialect = .anthropic_messages,
        .phase = .request_started,
        .exchange = exchange,
        .observed_at_ms = 100,
    }));
    try std.testing.expect(agent.applyProxy(.{
        .identity = identity,
        .dialect = .anthropic_messages,
        .phase = .provider_turn_completed,
        .exchange = exchange,
        .observed_at_ms = 200,
    }));

    const evidence = agent.proxy.currentEvidence().?;
    try std.testing.expectEqual(core.AgentStatus.ready, evidence.status);
    try std.testing.expectEqual(core.AgentProvider.pi, agent.provider());
}

test "semantic completion does not clear stronger blocked screen evidence" {
    const identity = try testIdentity();
    var agent = init(identity);
    const exchange: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };

    _ = agent.applyProxy(.{
        .identity = identity,
        .dialect = .anthropic_messages,
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
        .dialect = .anthropic_messages,
        .phase = .provider_turn_completed,
        .exchange = exchange,
        .observed_at_ms = 200,
    }));
    try std.testing.expectEqual(core.AgentAuthority.obscured, agent.authority);
    try std.testing.expect(agent.screen != null);
    try std.testing.expectEqual(core.AgentStatus.blocked, agent.chooseEvidence(200).?.status);
}

test "agent coalesces frequent proxy activity" {
    const identity = try testIdentity();
    var agent = init(identity);
    const exchange: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };

    try std.testing.expect(agent.applyProxy(.{
        .identity = identity,
        .dialect = .anthropic_messages,
        .phase = .request_started,
        .exchange = exchange,
        .observed_at_ms = 100,
    }));
    try std.testing.expect(!agent.applyProxy(.{
        .identity = identity,
        .dialect = .anthropic_messages,
        .phase = .response_activity,
        .exchange = exchange,
        .observed_at_ms = 100 + types.activity_refresh_ms - 1,
    }));
    try std.testing.expectEqual(@as(i64, 100), agent.proxy.currentEvidence().?.observed_at_ms);

    const refreshed_at = 100 + types.activity_refresh_ms;
    try std.testing.expect(agent.applyProxy(.{
        .identity = identity,
        .dialect = .anthropic_messages,
        .phase = .response_activity,
        .exchange = exchange,
        .observed_at_ms = refreshed_at,
    }));
    try std.testing.expectEqual(refreshed_at, agent.proxy.currentEvidence().?.observed_at_ms);
    try std.testing.expectEqual(refreshed_at + types.working_expiry_ms, agent.proxy.currentEvidence().?.expires_at_ms);
}

test "new proxy work resumes an obscured agent" {
    const identity = try testIdentity();
    var agent = init(identity);
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
        .dialect = .anthropic_messages,
        .phase = .request_started,
        .exchange = exchange,
        .observed_at_ms = 100,
    }));
    try std.testing.expectEqual(core.AgentAuthority.resumed, agent.authority);
    try std.testing.expect(agent.screen == null);
}

/// What a lifecycle report says beyond its state: why the agent is blocked
/// and one line naming the moment. It is shown only while that report is
/// the evidence the projection follows.
const ReportDetail = struct {
    blocked_reason: core.AgentBlockedReason = .none,
    event: EventLine = .{},
};
