//! Runtime-owned agent evidence and projection.
//!
//! Process, network, and terminal observers publish bounded evidence here.
//! This registry is the only place that turns those observations into sidebar
//! state, so another detector cannot bypass precedence, expiry, or
//! pane-generation checks.

const std = @import("std");
const core = @import("telar-core");
const detection = @import("../history/root.zig").detection;
const pane_mod = @import("../pane/root.zig");
pub const description = @import("description.zig");

const schema = core.schema;
const Pane = pane_mod.Pane;
const PaneKey = pane_mod.PaneKey;

pub const max_records = schema.max_agent_snapshot_entries;
pub const working_expiry_ms: i64 = 2 * 60 * 1000;
pub const settled_expiry_ms: i64 = 30 * 60 * 1000;
pub const activity_refresh_ms: i64 = 5 * 1000;
pub const max_active_proxy_requests = 128;

pub const ScreenStatus = detection.Status;
pub const ScreenSignal = detection.Signal;

pub const Identity = struct {
    key: PaneKey,
    process_id: u32,
    session_id: [16]u8,

    pub fn fromPane(pane: *const Pane) Identity {
        return .{
            .key = pane.key(),
            .process_id = std.math.cast(u32, pane.session.pid) orelse 0,
            .session_id = pane.history_session_id,
        };
    }
};

pub const ProxyPhase = enum {
    request_started,
    response_activity,
    response_finished,
    request_failed,
};

pub const ProxyProtocol = enum { http11, h2, upgraded };

const Evidence = struct {
    provider: schema.AgentProvider,
    status: schema.AgentStatus,
    source: schema.AgentSource,
    confidence: u8,
    observed_at_ms: i64,
    expires_at_ms: i64,

    /// Converts one accepted proxy observation into expiring agent evidence.
    fn fromProxyObservation(observation: *const ProxyObservation) Evidence {
        const status: schema.AgentStatus = switch (observation.phase) {
            .request_started, .response_activity, .response_finished => .working,
            .request_failed => .failed,
        };

        return .{
            .provider = observation.provider,
            .status = status,
            .source = .proxy_tls,
            .confidence = switch (observation.phase) {
                .request_started, .response_finished => 95,
                .response_activity => 90,
                .request_failed => 98,
            },
            .observed_at_ms = observation.observed_at_ms,
            .expires_at_ms = observation.observed_at_ms + if (status == .working)
                working_expiry_ms
            else
                settled_expiry_ms,
        };
    }

    fn isWorking(evidence: *const Evidence) bool {
        return evidence.status == .working;
    }
};

const Agent = struct {
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

    fn applyProxy(agent: *Agent, observation: ProxyObservation) bool {
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

/// Identifies one intercepted model exchange within the proxy observation
/// stream.
///
/// `stream_id` is zero for HTTP/1.1 and upgraded connections. HTTP/2 normally
/// uses its peer stream identifier; a `request_failed` observation may use zero
/// to settle every active stream on the named connection.
pub const ProxyExchange = struct {
    protocol: ProxyProtocol,
    connection_id: u64,
    stream_id: u32,
};

/// Owned proxy evidence enriched by the runtime with the exact agent identity
/// that was active when the observation arrived.
///
/// The exchange identifies the network work being observed, while
/// `observed_at_ms` orders evidence and determines its expiry. Callers exclude
/// auxiliary provider traffic before constructing this value.
pub const ProxyObservation = struct {
    identity: Identity,
    provider: schema.AgentProvider,
    phase: ProxyPhase,
    exchange: ProxyExchange,
    observed_at_ms: i64,

    fn requiresTrackedExchange(observation: *const ProxyObservation) bool {
        return observation.phase != .request_started;
    }

    fn hasSameProvider(observation: *const ProxyObservation, evidence: *const Evidence) bool {
        return observation.provider == evidence.provider;
    }

    fn isResponseActivity(observation: *const ProxyObservation) bool {
        return observation.phase == .response_activity;
    }
};

const ProxyState = struct {
    const ApplyResult = enum {
        ignored,
        activity_refreshed,
        evidence_replaced,
    };

    evidence: ?Evidence = null,
    active: [max_active_proxy_requests]?ProxyExchange = @splat(null),
    active_count: u16 = 0,

    fn replaceEvidence(state: *ProxyState, observation: *const ProxyObservation) void {
        state.evidence = Evidence.fromProxyObservation(observation);
    }

    fn apply(state: *ProxyState, observation: ProxyObservation) ApplyResult {
        const tracked = state.track(observation.phase, observation.exchange);

        if (observation.requiresTrackedExchange() and !tracked) {
            return .ignored;
        }

        if (observation.isResponseActivity()) {
            if (state.evidence) |*evidence| {
                if (observation.hasSameProvider(evidence) and evidence.isWorking()) {
                    if (observation.observed_at_ms - evidence.observed_at_ms < activity_refresh_ms) {
                        return .ignored;
                    }

                    evidence.observed_at_ms = observation.observed_at_ms;
                    evidence.expires_at_ms = observation.observed_at_ms + working_expiry_ms;
                    return .activity_refreshed;
                }
            }
        }

        state.replaceEvidence(&observation);
        return .evidence_replaced;
    }

    fn track(state: *ProxyState, phase: ProxyPhase, exchange: ProxyExchange) bool {
        return switch (phase) {
            .request_started => state.start(exchange),
            .response_activity => state.contains(exchange),
            .response_finished, .request_failed => state.settle(exchange),
        };
    }

    fn start(state: *ProxyState, exchange: ProxyExchange) bool {
        var free: ?*?ProxyExchange = null;

        for (&state.active) |*slot| {
            if (slot.*) |active| {
                if (sameProxyExchange(active, exchange)) {
                    return false;
                }
            } else if (free == null) {
                free = slot;
            }
        }

        const destination = free orelse return false;
        destination.* = exchange;
        state.active_count += 1;
        return true;
    }

    fn contains(state: *const ProxyState, exchange: ProxyExchange) bool {
        for (state.active) |active| {
            if (active != null and sameProxyExchange(active.?, exchange)) {
                return true;
            }
        }

        return false;
    }

    fn settle(state: *ProxyState, exchange: ProxyExchange) bool {
        if (exchange.protocol == .h2 and exchange.stream_id == 0) {
            var removed = false;

            for (&state.active) |*slot| {
                const active = slot.* orelse continue;

                if (active.protocol != .h2 or active.connection_id != exchange.connection_id) {
                    continue;
                }

                slot.* = null;
                state.active_count -= 1;
                removed = true;
            }
            return removed;
        }

        for (&state.active) |*slot| {
            const active = slot.* orelse continue;

            if (!sameProxyExchange(active, exchange)) {
                continue;
            }

            slot.* = null;
            state.active_count -= 1;
            return true;
        }

        return false;
    }

    fn clear(state: *ProxyState) void {
        state.evidence = null;
        state.active = @splat(null);
        state.active_count = 0;
    }
};

pub const Registry = struct {
    records: [max_records]?Agent = @splat(null),
    revision: u64 = 1,
    sequence: u64 = 0,

    pub fn observeProcess(store: *Registry, identity: Identity, provider: schema.AgentProvider, process_id: u32, observed_at_ms: i64) bool {
        if (provider == .unknown or process_id == 0) return false;
        var record = store.ensure(identity) orelse return false;
        const replaced_process = record.process != null;
        if (record.process) |evidence| {
            if (evidence.provider == provider and record.agent_process_id == process_id)
                return false;
            record.screen = null;
            record.proxy.clear();
        }
        record.agent_process_id = process_id;
        record.process = .{
            .provider = provider,
            .status = .ready,
            .source = .foreground_process,
            .confidence = 100,
            .observed_at_ms = observed_at_ms,
            .expires_at_ms = std.math.maxInt(i64),
        };
        record.authority = if (replaced_process) .active else switch (record.authority) {
            .candidate, .stale, .exited => .active,
            .active, .obscured, .resumed => record.authority,
        };
        return store.reproject(record, observed_at_ms);
    }

    /// A foreground process-group change is authoritative session exit. Old
    /// proxy and screen evidence belongs to that process and must not keep its
    /// sidebar row alive after the shell regains control.
    pub fn clearProcess(store: *Registry, key: PaneKey) bool {
        const record = store.find(key) orelse return false;
        if (record.process == null) return false;
        return store.remove(key);
    }

    /// Applies one proxy lifecycle observation to the agent identified by
    /// `observation.identity`.
    ///
    /// `request_started` opens a bounded tracked exchange and may create the
    /// agent record. Activity, completion, and failure observations require a
    /// matching exchange; unmatched observations cannot create or settle agent
    /// state. Callers must filter auxiliary requests before calling this method.
    ///
    /// An accepted observation refreshes proxy evidence and recomputes the
    /// public agent projection. A successful HTTP response remains `working`
    /// because transport completion does not prove that the agent turn ended.
    /// The return value is `true` only when the projected snapshot or title
    /// state changed. This method does not parse HTTP bodies or provider events.
    ///
    /// ```zig
    /// fn observeHttp11Exchange(registry: *Registry, identity: Identity) void {
    ///     const exchange: ProxyExchange = .{
    ///         .protocol = .http11,
    ///         .connection_id = 17,
    ///         .stream_id = 0,
    ///     };
    ///     _ = registry.observeProxy(.{
    ///         .identity = identity,
    ///         .provider = .claude,
    ///         .phase = .request_started,
    ///         .exchange = exchange,
    ///         .observed_at_ms = 1_000,
    ///     });
    ///     _ = registry.observeProxy(.{
    ///         .identity = identity,
    ///         .provider = .claude,
    ///         .phase = .response_activity,
    ///         .exchange = exchange,
    ///         .observed_at_ms = 1_100,
    ///     });
    ///     _ = registry.observeProxy(.{
    ///         .identity = identity,
    ///         .provider = .claude,
    ///         .phase = .response_finished,
    ///         .exchange = exchange,
    ///         .observed_at_ms = 1_200,
    ///     });
    /// }
    /// ```
    pub fn observeProxy(registry: *Registry, observation: ProxyObservation) bool {
        if (observation.provider == .unknown) {
            return false;
        }

        const agent = registry.resolveProxyAgent(&observation) orelse return false;
        if (!agent.applyProxy(observation)) {
            return false;
        }

        return registry.reproject(agent, observation.observed_at_ms);
    }

    pub fn observeScreen(store: *Registry, identity: Identity, signal: ScreenSignal, observed_at_ms: i64) bool {
        const existing = store.find(identity.key);
        const process_provider = if (existing) |record|
            if (record.process) |evidence| evidence.provider else schema.AgentProvider.unknown
        else
            .unknown;
        if (process_provider != .unknown and signal.provider != .unknown and
            signal.provider != process_provider) return false;
        const known_provider = if (process_provider != .unknown)
            process_provider
        else if (signal.provider != .unknown)
            signal.provider
        else if (existing) |record|
            recordProvider(record)
        else
            .unknown;
        // `❯` is also a popular shell prompt and generic confirmation text is
        // not agent identity. A ready prompt needs prior provider evidence or
        // a detector signal tied to explicit provider branding.
        if (signal.status == .ready and
            !signal.identity_confirmed and
            (existing == null or recordProvider(existing.?) != signal.provider)) return false;
        if (known_provider == .unknown) return false;
        var record = store.ensure(identity) orelse return false;
        // A branded header or a prompt glyph seen in raw output cannot settle
        // live work. `ready_confirmed` means the observer found the prompt next
        // to the visible cursor in its emulated terminal.
        if (signal.status == .ready and
            currentStatus(record) == .working and
            !signal.ready_confirmed) return false;
        record.screen = .{
            .provider = known_provider,
            .status = switch (signal.status) {
                .working => .working,
                .blocked => .blocked,
                .ready => .ready,
            },
            .source = .screen,
            .confidence = signal.confidence,
            .observed_at_ms = observed_at_ms,
            .expires_at_ms = observed_at_ms + switch (signal.status) {
                .working => working_expiry_ms,
                .blocked, .ready => settled_expiry_ms,
            },
        };
        if (signal.status == .blocked) record.authority = .obscured;
        return store.reproject(record, observed_at_ms);
    }

    pub fn expire(store: *Registry, now_ms: i64) bool {
        var changed = false;
        for (&store.records) |*slot| {
            var record = if (slot.*) |*value| value else continue;
            if (record.proxy.evidence) |evidence| {
                if (evidence.expires_at_ms <= now_ms) {
                    record.proxy.clear();
                }
            }
            if (record.screen) |evidence| {
                if (evidence.expires_at_ms <= now_ms) record.screen = null;
            }
            if (record.process == null and record.proxy.evidence == null and record.screen == null) {
                record.authority = .stale;
                record.title.clearSensitive();
                slot.* = null;
                store.bumpRevision();
                changed = true;
                continue;
            }
            changed = store.reproject(record, now_ms) or changed;
        }
        return changed;
    }

    pub fn remove(store: *Registry, key: PaneKey) bool {
        for (&store.records) |*slot| {
            var record = if (slot.*) |*value| value else continue;
            if (!sameKey(record.key, key)) continue;
            record.title.clearSensitive();
            slot.* = null;
            store.bumpRevision();
            return true;
        }
        return false;
    }

    pub fn snapshot(store: *const Registry, entries: *[max_records]schema.AgentSnapshotEntry) []const schema.AgentSnapshotEntry {
        var count: usize = 0;
        for (&store.records) |*slot| {
            const record = if (slot.*) |*value| value else continue;
            entries[count] = record.projected;
            entries[count].session_title = record.title.slice();
            entries[count].title_source = record.title.source;
            entries[count].title_state = record.title.state;
            count += 1;
        }
        return entries[0..count];
    }

    pub fn projectedStatus(store: *const Registry, key: PaneKey) ?schema.AgentStatus {
        for (&store.records) |*slot| {
            const record = if (slot.*) |*value| value else continue;
            if (sameKey(record.key, key)) return record.projected.status;
        }
        return null;
    }

    /// Captures only the first submitted request for an already identified
    /// agent. Callers gate this method on explicit description configuration.
    pub fn observeInput(store: *Registry, key: PaneKey, bytes: []const u8) bool {
        const record = store.find(key) orelse return false;
        if (record.title.phase != .waiting_query) return false;
        if (!record.title.capture.feed(bytes)) return false;
        record.title.phase = .waiting_work;
        return true;
    }

    /// Starts one bounded job at a time. Invalid captured input deterministically
    /// becomes a failed placeholder and is never retried.
    pub fn nextDescriptionJob(store: *Registry) ?description.Job {
        for (&store.records) |*slot| {
            const record = if (slot.*) |*value| value else continue;
            if (record.title.phase == .running) return null;
        }
        for (&store.records) |*slot| {
            var record = if (slot.*) |*value| value else continue;
            if (record.title.phase != .queued) continue;
            var normalized: [description.max_query_bytes]u8 = undefined;
            const query = description.normalizeQuery(record.title.capture.raw(), &normalized) catch {
                record.title.phase = .failed;
                record.title.state = .failed;
                record.title.clearSensitive();
                store.bumpRevision();
                continue;
            };
            var job: description.Job = .{
                .pane = record.key,
                .session_id = record.session_id,
                .provider = recordProvider(record),
                .query_len = @intCast(query.len),
            };
            @memcpy(job.query[0..query.len], query);
            std.crypto.secureZero(u8, &normalized);
            record.title.clearSensitive();
            record.title.phase = .running;
            return job;
        }
        return null;
    }

    /// A completion applies only to the exact session which launched it. A
    /// manual title changes the phase, so a concurrent generated result is
    /// stale by construction.
    pub fn finishDescription(store: *Registry, result: *const description.Result) bool {
        const record = store.find(result.pane) orelse return false;
        if (record.title.phase != .running or
            !std.mem.eql(u8, &record.session_id, &result.session_id)) return false;
        if (result.status == .success) {
            const title = result.titleSlice();
            if (title.len == 0 or title.len > record.title.bytes.len or
                !validTitle(title))
            {
                record.title.phase = .failed;
                record.title.state = .failed;
            } else {
                @memcpy(record.title.bytes[0..title.len], title);
                record.title.len = @intCast(title.len);
                record.title.source = .generated;
                record.title.state = .ready;
                record.title.phase = .finished;
            }
        } else {
            record.title.phase = .failed;
            record.title.state = .failed;
        }
        store.bumpRevision();
        return true;
    }

    pub fn setManualTitle(store: *Registry, key: PaneKey, value: []const u8) !bool {
        const record = store.find(key) orelse return false;
        if (!validTitle(value) or value.len > record.title.bytes.len)
            return error.InvalidAgentTitle;
        record.title.clearSensitive();
        @memcpy(record.title.bytes[0..value.len], value);
        record.title.len = @intCast(value.len);
        record.title.source = .manual;
        record.title.state = .ready;
        record.title.phase = .finished;
        store.bumpRevision();
        return true;
    }

    /// Publishes pane-topology changes that alter the display position of
    /// otherwise unchanged agent records.
    pub fn touch(store: *Registry) void {
        store.bumpRevision();
    }

    fn resolveProxyAgent(registry: *Registry, observation: *const ProxyObservation) ?*Agent {
        return switch (observation.phase) {
            .request_started => registry.ensure(observation.identity),
            .response_activity, .response_finished, .request_failed => registry.find(observation.identity.key),
        };
    }

    fn ensure(store: *Registry, identity: Identity) ?*Agent {
        const key = identity.key;
        if (store.find(key)) |record| return record;
        for (&store.records) |*slot| {
            if (slot.* != null) continue;
            slot.* = .{
                .key = key,
                .process_id = identity.process_id,
                .session_id = identity.session_id,
                .projected = .{
                    .pane_id = key.id,
                    .pane_generation = key.generation,
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
            return &slot.*.?;
        }
        return null;
    }

    fn find(store: *Registry, key: PaneKey) ?*Agent {
        for (&store.records) |*slot| {
            const record = if (slot.*) |*value| value else continue;
            if (sameKey(record.key, key)) return record;
        }
        return null;
    }

    fn reproject(store: *Registry, record: *Agent, now_ms: i64) bool {
        const evidence = chooseEvidence(record, now_ms) orelse return false;

        const provider = if (record.process) |process|
            process.provider
        else if (evidence.provider != .unknown)
            evidence.provider
        else if (record.proxy.evidence) |proxy|
            proxy.provider
        else if (record.screen) |screen|
            screen.provider
        else
            .unknown;

        const previous = record.projected;
        ensurePlaceholder(record, provider);
        store.sequence +%= 1;

        if (store.sequence == 0) {
            store.sequence = 1;
        }

        record.projected = .{
            .pane_id = record.key.id,
            .pane_generation = record.key.generation,
            .process_id = record.agent_process_id orelse record.process_id,
            .session_id = record.session_id,
            .provider = provider,
            .status = evidence.status,
            .source = evidence.source,
            .authority = record.authority,
            .confidence = evidence.confidence,
            .sequence = store.sequence,
            .observed_at_ms = evidence.observed_at_ms,
            .expires_at_ms = evidence.expires_at_ms,
        };

        const title_changed = store.advanceTitle(record, evidence.status);

        if (sameProjection(previous, record.projected)) {
            record.projected.sequence = previous.sequence;
            if (title_changed) store.bumpRevision();
            return title_changed;
        }

        store.bumpRevision();
        return true;
    }

    fn advanceTitle(store: *const Registry, record: *Agent, status: schema.AgentStatus) bool {
        // Model work confirms that the captured input was a real request. The
        // title generator can now run alongside the turn instead of waiting
        // for the agent to return to its prompt.
        if (record.title.phase != .waiting_work or status != .working) return false;
        if (store.pendingDescriptionCount() >= description.max_pending_jobs) {
            record.title.phase = .failed;
            record.title.state = .failed;
            record.title.clearSensitive();
        } else {
            record.title.phase = .queued;
            record.title.state = .pending;
        }
        return true;
    }

    fn pendingDescriptionCount(store: *const Registry) usize {
        var count: usize = 0;
        for (&store.records) |*slot| {
            const record = if (slot.*) |*value| value else continue;
            if (record.title.phase == .queued or record.title.phase == .running)
                count += 1;
        }
        return count;
    }

    fn bumpRevision(store: *Registry) void {
        store.revision +%= 1;
        if (store.revision == 0) store.revision = 1;
    }
};

fn sameProxyExchange(left: ProxyExchange, right: ProxyExchange) bool {
    return left.protocol == right.protocol and
        left.connection_id == right.connection_id and
        left.stream_id == right.stream_id;
}

fn chooseEvidence(record: *const Agent, now_ms: i64) ?Evidence {
    const process = record.process;
    const screen = if (record.screen) |value|
        if (value.expires_at_ms > now_ms) value else null
    else
        null;
    const proxy = if (record.proxy.evidence) |value|
        if (value.expires_at_ms > now_ms) value else null
    else
        null;

    // A permission prompt is visible truth. Active terminal work also wins
    // over network activity, while proxy work wins over an older idle prompt.
    if (screen) |value| if (value.status == .blocked) return value;
    if (screen) |value| if (value.status == .working) return value;
    // A ready screen reaches the store only after the observer confirms an
    // input prompt at the visible cursor.
    if (proxy) |proxy_work| if (proxy_work.status == .working) {
        // A confirmed prompt may repair a dropped completion, but it must not
        // mask network work which started after that prompt was sampled.
        if (screen) |screen_ready| if (screen_ready.status == .ready and
            screen_ready.observed_at_ms > proxy_work.observed_at_ms) return screen_ready;
        return proxy_work;
    };
    if (screen) |value| if (value.status == .ready) return value;
    if (proxy) |value| return value;
    if (screen) |value| return value;
    return process;
}

fn currentStatus(record: *const Agent) schema.AgentStatus {
    return record.projected.status;
}

fn recordProvider(record: *const Agent) schema.AgentProvider {
    if (record.process) |evidence| {
        return evidence.provider;
    }

    if (record.proxy.evidence) |evidence| {
        if (evidence.provider != .unknown) {
            return evidence.provider;
        }
    }

    if (record.screen) |evidence| {
        return evidence.provider;
    }

    return .unknown;
}

fn ensurePlaceholder(record: *Agent, provider: schema.AgentProvider) void {
    if (record.title.source != .telar) return;
    const placeholder = switch (provider) {
        .codex => "New Codex session",
        .claude => "New Claude Code session",
        .unknown => "New agent session",
    };
    if (std.mem.eql(u8, record.title.slice(), placeholder)) return;
    @memcpy(record.title.bytes[0..placeholder.len], placeholder);
    record.title.len = @intCast(placeholder.len);
}

fn validTitle(value: []const u8) bool {
    if (value.len == 0 or value.len > schema.max_agent_session_title_bytes or
        !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

fn sameKey(a: PaneKey, b: PaneKey) bool {
    return a.id == b.id and a.generation == b.generation;
}

fn sameProjection(a: schema.AgentSnapshotEntry, b: schema.AgentSnapshotEntry) bool {
    var left = a;
    var right = b;
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

fn observeTestProxy(store: *Registry, identity: Identity, provider: schema.AgentProvider, phase: ProxyPhase, observed_at_ms: i64) bool {
    return store.observeProxy(.{
        .identity = identity,
        .provider = provider,
        .phase = phase,
        .observed_at_ms = observed_at_ms,
        .exchange = .{
            .protocol = .h2,
            .connection_id = 1,
            .stream_id = 1,
        },
    });
}

fn observeTestReadyPrompt(store: *Registry, identity: Identity, provider: schema.AgentProvider, observed_at_ms: i64) bool {
    return store.observeScreen(
        identity,
        .{
            .provider = provider,
            .status = .ready,
            .confidence = 96,
            .identity_confirmed = true,
            .ready_confirmed = true,
        },
        observed_at_ms,
    );
}

test "proxy evidence derives status confidence and expiry from its phase" {
    const identity = try testIdentity();
    const exchange: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };
    const observed_at_ms: i64 = 100;
    const expectations = [_]struct {
        phase: ProxyPhase,
        status: schema.AgentStatus,
        confidence: u8,
        lifetime_ms: i64,
    }{
        .{ .phase = .request_started, .status = .working, .confidence = 95, .lifetime_ms = working_expiry_ms },
        .{ .phase = .response_activity, .status = .working, .confidence = 90, .lifetime_ms = working_expiry_ms },
        .{ .phase = .response_finished, .status = .working, .confidence = 95, .lifetime_ms = working_expiry_ms },
        .{ .phase = .request_failed, .status = .failed, .confidence = 98, .lifetime_ms = settled_expiry_ms },
    };

    for (expectations) |expectation| {
        const observation: ProxyObservation = .{
            .identity = identity,
            .provider = .claude,
            .phase = expectation.phase,
            .exchange = exchange,
            .observed_at_ms = observed_at_ms,
        };
        const evidence = Evidence.fromProxyObservation(&observation);

        try std.testing.expectEqual(schema.AgentProvider.claude, evidence.provider);
        try std.testing.expectEqual(expectation.status, evidence.status);
        try std.testing.expectEqual(schema.AgentSource.proxy_tls, evidence.source);
        try std.testing.expectEqual(expectation.confidence, evidence.confidence);
        try std.testing.expectEqual(observed_at_ms, evidence.observed_at_ms);
        try std.testing.expectEqual(observed_at_ms + expectation.lifetime_ms, evidence.expires_at_ms);
    }
}

test "proxy state starts an exchange" {
    var state: ProxyState = .{};
    const exchange: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };

    try std.testing.expect(state.start(exchange));
    try std.testing.expect(state.contains(exchange));
    try std.testing.expectEqual(@as(u16, 1), state.active_count);
}

test "proxy state rejects a duplicate exchange without changing its count" {
    var state: ProxyState = .{};
    const exchange: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };

    try std.testing.expect(state.start(exchange));
    try std.testing.expect(!state.start(exchange));
    try std.testing.expect(state.contains(exchange));
    try std.testing.expectEqual(@as(u16, 1), state.active_count);
}

test "proxy state does not exceed its bounded exchange capacity" {
    var state: ProxyState = .{};

    for (0..max_active_proxy_requests) |index| {
        const exchange: ProxyExchange = .{
            .protocol = .h2,
            .connection_id = 7,
            .stream_id = @intCast(index + 1),
        };
        try std.testing.expect(state.start(exchange));
    }

    const overflow: ProxyExchange = .{
        .protocol = .h2,
        .connection_id = 7,
        .stream_id = @intCast(max_active_proxy_requests + 1),
    };
    try std.testing.expect(!state.start(overflow));
    try std.testing.expect(!state.contains(overflow));
    try std.testing.expectEqual(@as(u16, max_active_proxy_requests), state.active_count);
}

test "proxy state settles only the specified exchange" {
    var state: ProxyState = .{};
    const settled: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };
    const remaining: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 3 };

    try std.testing.expect(state.start(settled));
    try std.testing.expect(state.start(remaining));
    try std.testing.expect(state.settle(settled));

    try std.testing.expect(!state.contains(settled));
    try std.testing.expect(state.contains(remaining));
    try std.testing.expectEqual(@as(u16, 1), state.active_count);
    try std.testing.expect(!state.settle(settled));
    try std.testing.expectEqual(@as(u16, 1), state.active_count);
}

test "proxy state HTTP2 sentinel settles only its connection streams" {
    var state: ProxyState = .{};
    const first: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };
    const second: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 3 };
    const other_connection: ProxyExchange = .{ .protocol = .h2, .connection_id = 8, .stream_id = 1 };
    const other_protocol: ProxyExchange = .{ .protocol = .http11, .connection_id = 7, .stream_id = 0 };
    const connection: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 0 };

    try std.testing.expect(state.start(first));
    try std.testing.expect(state.start(second));
    try std.testing.expect(state.start(other_connection));
    try std.testing.expect(state.start(other_protocol));
    try std.testing.expect(state.settle(connection));

    try std.testing.expect(!state.contains(first));
    try std.testing.expect(!state.contains(second));
    try std.testing.expect(state.contains(other_connection));
    try std.testing.expect(state.contains(other_protocol));
    try std.testing.expectEqual(@as(u16, 2), state.active_count);
}

test "proxy state clear removes evidence and every active exchange" {
    var state: ProxyState = .{};
    const first: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };
    const second: ProxyExchange = .{ .protocol = .http11, .connection_id = 8, .stream_id = 0 };

    state.evidence = .{
        .provider = .claude,
        .status = .working,
        .source = .proxy_tls,
        .confidence = 95,
        .observed_at_ms = 100,
        .expires_at_ms = 200,
    };
    try std.testing.expect(state.start(first));
    try std.testing.expect(state.start(second));

    state.clear();

    try std.testing.expect(state.evidence == null);
    try std.testing.expectEqual(@as(u16, 0), state.active_count);
    for (state.active) |exchange| {
        try std.testing.expect(exchange == null);
    }
}

test "agent rejects an untracked proxy response" {
    var registry: Registry = .{};
    const identity = try testIdentity();
    const agent = registry.ensure(identity).?;
    const exchange: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };

    try std.testing.expect(!agent.applyProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .response_activity,
        .exchange = exchange,
        .observed_at_ms = 100,
    }));
    try std.testing.expect(agent.proxy.evidence == null);
    try std.testing.expectEqual(@as(u16, 0), agent.proxy.active_count);
    try std.testing.expectEqual(schema.AgentAuthority.candidate, agent.authority);
}

test "agent applies a tracked proxy lifecycle" {
    var registry: Registry = .{};
    const identity = try testIdentity();
    const agent = registry.ensure(identity).?;
    const exchange: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };

    try std.testing.expect(agent.applyProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .request_started,
        .exchange = exchange,
        .observed_at_ms = 100,
    }));
    try std.testing.expectEqual(schema.AgentAuthority.active, agent.authority);
    try std.testing.expectEqual(@as(u16, 1), agent.proxy.active_count);

    try std.testing.expect(agent.applyProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .response_finished,
        .exchange = exchange,
        .observed_at_ms = 200,
    }));

    const evidence = agent.proxy.evidence.?;
    try std.testing.expectEqual(schema.AgentProvider.claude, evidence.provider);
    try std.testing.expectEqual(schema.AgentStatus.working, evidence.status);
    try std.testing.expectEqual(schema.AgentSource.proxy_tls, evidence.source);
    try std.testing.expectEqual(@as(i64, 200), evidence.observed_at_ms);
    try std.testing.expectEqual(@as(u16, 0), agent.proxy.active_count);
}

test "agent coalesces frequent proxy activity" {
    var registry: Registry = .{};
    const identity = try testIdentity();
    const agent = registry.ensure(identity).?;
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
        .observed_at_ms = 100 + activity_refresh_ms - 1,
    }));
    try std.testing.expectEqual(@as(i64, 100), agent.proxy.evidence.?.observed_at_ms);

    const refreshed_at = 100 + activity_refresh_ms;
    try std.testing.expect(agent.applyProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .response_activity,
        .exchange = exchange,
        .observed_at_ms = refreshed_at,
    }));
    try std.testing.expectEqual(refreshed_at, agent.proxy.evidence.?.observed_at_ms);
    try std.testing.expectEqual(refreshed_at + working_expiry_ms, agent.proxy.evidence.?.expires_at_ms);
}

test "new proxy work resumes an obscured agent" {
    var registry: Registry = .{};
    const identity = try testIdentity();
    const agent = registry.ensure(identity).?;
    const exchange: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };

    agent.authority = .obscured;
    agent.screen = .{
        .provider = .claude,
        .status = .blocked,
        .source = .screen,
        .confidence = 88,
        .observed_at_ms = 50,
        .expires_at_ms = settled_expiry_ms,
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

test "display context changes advance the public snapshot revision" {
    var store: Registry = .{};
    const before = store.revision;
    store.touch();
    try std.testing.expectEqual(before + 1, store.revision);
}

test "only a confirmed prompt settles model work" {
    var store: Registry = .{};
    const identity = try testIdentity();
    try std.testing.expect(observeTestProxy(&store, identity, .claude, .request_started, 100));
    try std.testing.expect(observeTestProxy(&store, identity, .claude, .response_finished, 200));
    try std.testing.expect(!store.observeScreen(
        identity,
        .{
            .provider = .claude,
            .status = .ready,
            .confidence = 90,
            .identity_confirmed = true,
        },
        300,
    ));
    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    var snapshot = store.snapshot(&entries);
    try std.testing.expectEqual(@as(usize, 1), snapshot.len);
    try std.testing.expectEqual(schema.AgentStatus.working, snapshot[0].status);
    try std.testing.expectEqual(schema.AgentSource.proxy_tls, snapshot[0].source);

    try std.testing.expect(observeTestReadyPrompt(&store, identity, .claude, 400));
    snapshot = store.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentStatus.ready, snapshot[0].status);
    try std.testing.expectEqual(schema.AgentSource.screen, snapshot[0].source);
}

test "explicit Codex prompt settles working without repetition" {
    var store: Registry = .{};
    const identity = try testIdentity();
    try std.testing.expect(observeTestProxy(&store, identity, .codex, .request_started, 100));
    try std.testing.expect(store.observeScreen(
        identity,
        .{
            .provider = .codex,
            .status = .ready,
            .confidence = 94,
            .identity_confirmed = true,
            .ready_confirmed = true,
        },
        200,
    ));

    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    const snapshot = store.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentStatus.ready, snapshot[0].status);
    try std.testing.expectEqual(schema.AgentSource.screen, snapshot[0].source);
}

test "agent branding alone does not settle working" {
    var store: Registry = .{};
    const identity = try testIdentity();
    try std.testing.expect(observeTestProxy(&store, identity, .claude, .request_started, 100));
    try std.testing.expect(!store.observeScreen(
        identity,
        .{
            .provider = .claude,
            .status = .ready,
            .confidence = 90,
            .identity_confirmed = true,
        },
        200,
    ));

    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    const snapshot = store.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentStatus.working, snapshot[0].status);
    try std.testing.expectEqual(schema.AgentSource.proxy_tls, snapshot[0].source);
}

test "explicitly identified ready screen opens an agent record" {
    var store: Registry = .{};
    const identity = try testIdentity();
    try std.testing.expect(store.observeScreen(
        identity,
        .{
            .provider = .codex,
            .status = .ready,
            .confidence = 94,
            .identity_confirmed = true,
        },
        100,
    ));
    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    const snapshot = store.snapshot(&entries);
    try std.testing.expectEqual(@as(usize, 1), snapshot.len);
    try std.testing.expectEqual(schema.AgentProvider.codex, snapshot[0].provider);
    try std.testing.expectEqual(schema.AgentStatus.ready, snapshot[0].status);
}

test "foreground process establishes agent identity without screen branding" {
    var store: Registry = .{};
    const identity = try testIdentity();
    try std.testing.expect(store.observeProcess(identity, .claude, 84, 100));

    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    var snapshot = store.snapshot(&entries);
    try std.testing.expectEqual(@as(usize, 1), snapshot.len);
    try std.testing.expectEqual(schema.AgentProvider.claude, snapshot[0].provider);
    try std.testing.expectEqual(schema.AgentStatus.ready, snapshot[0].status);
    try std.testing.expectEqual(schema.AgentSource.foreground_process, snapshot[0].source);
    try std.testing.expectEqual(@as(u32, 84), snapshot[0].process_id);

    try std.testing.expect(store.observeScreen(
        identity,
        .{ .provider = .unknown, .status = .working, .confidence = 78 },
        200,
    ));
    snapshot = store.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentProvider.claude, snapshot[0].provider);
    try std.testing.expectEqual(schema.AgentStatus.working, snapshot[0].status);
    try std.testing.expectEqual(schema.AgentSource.screen, snapshot[0].source);
    try std.testing.expectEqual(@as(u32, 84), snapshot[0].process_id);
}

test "first working turn starts one generated session title" {
    var store: Registry = .{};
    const identity = try testIdentity();
    try std.testing.expect(store.observeProcess(identity, .codex, 84, 100));
    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    var snapshot = store.snapshot(&entries);
    try std.testing.expectEqualStrings("New Codex session", snapshot[0].session_title);
    try std.testing.expectEqual(schema.AgentTitleState.placeholder, snapshot[0].title_state);

    try std.testing.expect(store.observeInput(identity.key, "improve the sidebar\r"));
    try std.testing.expect(observeTestReadyPrompt(&store, identity, .codex, 150));
    snapshot = store.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentTitleState.placeholder, snapshot[0].title_state);

    try std.testing.expect(observeTestProxy(&store, identity, .codex, .request_started, 200));
    snapshot = store.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentTitleState.pending, snapshot[0].title_state);

    var job = store.nextDescriptionJob().?;
    defer std.crypto.secureZero(u8, &job.query);
    try std.testing.expectEqualStrings("improve the sidebar", job.querySlice());
    var result: description.Result = .{
        .pane = job.pane,
        .session_id = job.session_id,
        .status = .success,
        .title_len = "Improve agent sidebar".len,
    };
    @memcpy(result.title[0..result.title_len], "Improve agent sidebar");
    try std.testing.expect(store.finishDescription(&result));
    snapshot = store.snapshot(&entries);
    try std.testing.expectEqualStrings("Improve agent sidebar", snapshot[0].session_title);
    try std.testing.expectEqual(schema.AgentTitleSource.generated, snapshot[0].title_source);
    try std.testing.expectEqual(schema.AgentTitleState.ready, snapshot[0].title_state);
    try std.testing.expect(store.nextDescriptionJob() == null);
}

test "manual title wins over a late generated result" {
    var store: Registry = .{};
    const identity = try testIdentity();
    try std.testing.expect(store.observeProcess(identity, .claude, 84, 100));
    try std.testing.expect(store.observeInput(identity.key, "fix tests\r"));
    try std.testing.expect(observeTestProxy(&store, identity, .claude, .request_started, 200));
    var job = store.nextDescriptionJob().?;
    defer std.crypto.secureZero(u8, &job.query);
    try std.testing.expect(try store.setManualTitle(identity.key, "Release audit"));

    var result: description.Result = .{
        .pane = job.pane,
        .session_id = job.session_id,
        .status = .success,
        .title_len = "Generated title".len,
    };
    @memcpy(result.title[0..result.title_len], "Generated title");
    try std.testing.expect(!store.finishDescription(&result));
    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    const snapshot = store.snapshot(&entries);
    try std.testing.expectEqualStrings("Release audit", snapshot[0].session_title);
    try std.testing.expectEqual(schema.AgentTitleSource.manual, snapshot[0].title_source);
}

test "description backpressure fails the ninth queued request without retry" {
    var store: Registry = .{};
    for (0..description.max_pending_jobs + 1) |index| {
        const raw: u64 = @intCast(index + 1);
        const identity: Identity = .{
            .key = .{ .id = try schema.id.pane(raw), .generation = raw },
            .process_id = @intCast(raw),
            .session_id = @splat(@intCast(raw)),
        };
        try std.testing.expect(store.observeProcess(identity, .codex, @intCast(raw), 100));
        try std.testing.expect(store.observeInput(identity.key, "do work\r"));
        try std.testing.expect(observeTestProxy(&store, identity, .codex, .request_started, 200));
    }
    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    const snapshot = store.snapshot(&entries);
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
    var store: Registry = .{};
    const identity = try testIdentity();
    try std.testing.expect(store.observeProcess(identity, .claude, 84, 100));
    try std.testing.expect(!store.observeScreen(
        identity,
        .{
            .provider = .codex,
            .status = .ready,
            .confidence = 94,
            .identity_confirmed = true,
        },
        200,
    ));

    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    const snapshot = store.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentProvider.claude, snapshot[0].provider);
    try std.testing.expectEqual(schema.AgentSource.foreground_process, snapshot[0].source);
}

test "foreground process exit removes all evidence for that session" {
    var store: Registry = .{};
    const identity = try testIdentity();
    try std.testing.expect(store.observeProcess(identity, .claude, 84, 100));
    try std.testing.expect(store.observeScreen(
        identity,
        .{ .provider = .unknown, .status = .blocked, .confidence = 88 },
        200,
    ));
    try std.testing.expect(store.clearProcess(identity.key));

    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    try std.testing.expectEqual(@as(usize, 0), store.snapshot(&entries).len);
}

test "new foreground process replaces prior session evidence" {
    var store: Registry = .{};
    const identity = try testIdentity();
    try std.testing.expect(store.observeProcess(identity, .claude, 84, 100));
    try std.testing.expect(store.observeScreen(
        identity,
        .{ .provider = .unknown, .status = .blocked, .confidence = 88 },
        200,
    ));
    try std.testing.expect(store.observeProcess(identity, .codex, 85, 300));

    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    const snapshot = store.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentProvider.codex, snapshot[0].provider);
    try std.testing.expectEqual(schema.AgentStatus.ready, snapshot[0].status);
    try std.testing.expectEqual(schema.AgentSource.foreground_process, snapshot[0].source);
    try std.testing.expectEqual(schema.AgentAuthority.active, snapshot[0].authority);
    try std.testing.expectEqual(@as(u32, 85), snapshot[0].process_id);
}

test "confirmed Claude prompt refreshes branded identity" {
    var store: Registry = .{};
    const identity = try testIdentity();
    try std.testing.expect(store.observeScreen(
        identity,
        .{
            .provider = .claude,
            .status = .ready,
            .confidence = 90,
            .identity_confirmed = true,
        },
        100,
    ));
    try std.testing.expect(observeTestReadyPrompt(&store, identity, .claude, 200));
    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    const snapshot = store.snapshot(&entries);
    try std.testing.expectEqual(@as(usize, 1), snapshot.len);
    try std.testing.expectEqual(schema.AgentProvider.claude, snapshot[0].provider);
    try std.testing.expectEqual(schema.AgentStatus.ready, snapshot[0].status);
    try std.testing.expectEqual(@as(i64, 200), snapshot[0].observed_at_ms);
}

test "network work resumes a visibly blocked agent" {
    var store: Registry = .{};
    const identity = try testIdentity();
    try std.testing.expect(store.observeScreen(
        identity,
        .{ .provider = .claude, .status = .blocked, .confidence = 88 },
        100,
    ));
    try std.testing.expect(observeTestProxy(&store, identity, .claude, .request_started, 200));
    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    const snapshot = store.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentStatus.working, snapshot[0].status);
    try std.testing.expectEqual(schema.AgentAuthority.resumed, snapshot[0].authority);
}

test "new network work supersedes an older ready prompt" {
    var store: Registry = .{};
    const identity = try testIdentity();
    try std.testing.expect(observeTestProxy(&store, identity, .claude, .request_started, 50));
    try std.testing.expect(observeTestProxy(&store, identity, .claude, .response_finished, 100));
    try std.testing.expect(observeTestReadyPrompt(&store, identity, .claude, 200));
    try std.testing.expect(observeTestProxy(&store, identity, .claude, .request_started, 300));
    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    const snapshot = store.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentStatus.working, snapshot[0].status);
    try std.testing.expectEqual(schema.AgentSource.proxy_tls, snapshot[0].source);
}

test "unmatched proxy responses cannot create agent state" {
    var store: Registry = .{};
    const identity = try testIdentity();
    const exchange: ProxyExchange = .{ .protocol = .h2, .connection_id = 9, .stream_id = 3 };
    try std.testing.expect(!store.observeProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .response_activity,
        .exchange = exchange,
        .observed_at_ms = 100,
    }));
    try std.testing.expect(!store.observeProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .request_failed,
        .exchange = exchange,
        .observed_at_ms = 200,
    }));

    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    try std.testing.expectEqual(@as(usize, 0), store.snapshot(&entries).len);
}

test "expired agent evidence is removed" {
    var store: Registry = .{};
    const identity = try testIdentity();
    try std.testing.expect(observeTestProxy(&store, identity, .codex, .request_started, 50));
    try std.testing.expect(observeTestProxy(&store, identity, .codex, .response_finished, 100));
    try std.testing.expect(store.expire(100 + settled_expiry_ms));
    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    try std.testing.expectEqual(@as(usize, 0), store.snapshot(&entries).len);
}

test "a bare shell prompt is not Claude identity" {
    var store: Registry = .{};
    const identity = try testIdentity();
    try std.testing.expect(!store.observeScreen(
        identity,
        .{ .provider = .claude, .status = .ready, .confidence = 72 },
        100,
    ));
    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    try std.testing.expectEqual(@as(usize, 0), store.snapshot(&entries).len);
}

test "completed HTTP2 streams do not settle the agent turn" {
    var store: Registry = .{};
    const identity = try testIdentity();
    const first: ProxyExchange = .{ .protocol = .h2, .connection_id = 9, .stream_id = 1 };
    const second: ProxyExchange = .{ .protocol = .h2, .connection_id = 9, .stream_id = 3 };
    try std.testing.expect(store.observeProxy(.{
        .identity = identity,
        .provider = .codex,
        .phase = .request_started,
        .exchange = first,
        .observed_at_ms = 100,
    }));
    _ = store.observeProxy(.{
        .identity = identity,
        .provider = .codex,
        .phase = .request_started,
        .exchange = second,
        .observed_at_ms = 101,
    });
    _ = store.observeProxy(.{
        .identity = identity,
        .provider = .codex,
        .phase = .response_finished,
        .exchange = first,
        .observed_at_ms = 200,
    });

    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    var snapshot = store.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentStatus.working, snapshot[0].status);
    _ = store.observeProxy(.{
        .identity = identity,
        .provider = .codex,
        .phase = .response_finished,
        .exchange = second,
        .observed_at_ms = 300,
    });
    snapshot = store.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentStatus.working, snapshot[0].status);

    try std.testing.expect(observeTestReadyPrompt(&store, identity, .codex, 400));
    snapshot = store.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentStatus.ready, snapshot[0].status);
}

test "sequential model requests stay working until a confirmed prompt" {
    var store: Registry = .{};
    const identity = try testIdentity();
    const first: ProxyExchange = .{ .protocol = .h2, .connection_id = 9, .stream_id = 1 };
    const second: ProxyExchange = .{ .protocol = .h2, .connection_id = 9, .stream_id = 3 };
    try std.testing.expect(store.observeProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .request_started,
        .exchange = first,
        .observed_at_ms = 100,
    }));
    try std.testing.expect(store.observeProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .response_finished,
        .exchange = first,
        .observed_at_ms = 200,
    }));

    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    var snapshot = store.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentStatus.working, snapshot[0].status);

    try std.testing.expect(store.observeProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .request_started,
        .exchange = second,
        .observed_at_ms = 300,
    }));
    try std.testing.expect(store.observeProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .response_finished,
        .exchange = second,
        .observed_at_ms = 400,
    }));
    snapshot = store.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentStatus.working, snapshot[0].status);

    try std.testing.expect(observeTestReadyPrompt(&store, identity, .claude, 500));
    snapshot = store.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentStatus.ready, snapshot[0].status);
    try std.testing.expectEqual(schema.AgentSource.screen, snapshot[0].source);
}

test "HTTP2 connection failure settles all of its active streams" {
    var store: Registry = .{};
    const identity = try testIdentity();
    const first: ProxyExchange = .{ .protocol = .h2, .connection_id = 11, .stream_id = 1 };
    const second: ProxyExchange = .{ .protocol = .h2, .connection_id = 11, .stream_id = 3 };
    const connection: ProxyExchange = .{ .protocol = .h2, .connection_id = 11, .stream_id = 0 };
    _ = store.observeProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .request_started,
        .exchange = first,
        .observed_at_ms = 100,
    });
    _ = store.observeProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .request_started,
        .exchange = second,
        .observed_at_ms = 101,
    });
    try std.testing.expect(store.observeProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .request_failed,
        .exchange = connection,
        .observed_at_ms = 200,
    }));
    try std.testing.expectEqual(@as(u16, 0), store.find(identity.key).?.proxy.active_count);
    try std.testing.expect(!store.observeProxy(.{
        .identity = identity,
        .provider = .claude,
        .phase = .request_failed,
        .exchange = connection,
        .observed_at_ms = 201,
    }));
}
