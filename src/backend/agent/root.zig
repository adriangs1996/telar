//! Runtime-owned agent evidence and projection.
//!
//! Process, network, and terminal observers publish bounded evidence here.
//! This store is the only place that turns those observations into sidebar
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

const ProxyRequest = struct {
    protocol: ProxyProtocol,
    connection_id: u64,
    stream_id: u32,
};

const Evidence = struct {
    provider: schema.AgentProvider,
    status: schema.AgentStatus,
    source: schema.AgentSource,
    confidence: u8,
    observed_at_ms: i64,
    expires_at_ms: i64,
};

const Record = struct {
    key: PaneKey,
    process_id: u32,
    agent_process_id: ?u32 = null,
    session_id: [16]u8,
    authority: schema.AgentAuthority = .candidate,
    process: ?Evidence = null,
    proxy: ?Evidence = null,
    active_proxy: [max_active_proxy_requests]?ProxyRequest = @splat(null),
    active_proxy_count: u16 = 0,
    screen: ?Evidence = null,
    title: Title = .{},
    projected: schema.AgentSnapshotEntry,
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

pub const Store = struct {
    records: [max_records]?Record = @splat(null),
    revision: u64 = 1,
    sequence: u64 = 0,

    pub fn observeProcess(
        store: *Store,
        identity: Identity,
        provider: schema.AgentProvider,
        process_id: u32,
        observed_at_ms: i64,
    ) bool {
        if (provider == .unknown or process_id == 0) return false;
        var record = store.ensure(identity) orelse return false;
        const replaced_process = record.process != null;
        if (record.process) |evidence| {
            if (evidence.provider == provider and record.agent_process_id == process_id)
                return false;
            record.screen = null;
            record.proxy = null;
            clearProxyActive(record);
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
    pub fn clearProcess(store: *Store, key: PaneKey) bool {
        const record = store.find(key) orelse return false;
        if (record.process == null) return false;
        return store.remove(key);
    }

    pub fn observeProxy(
        store: *Store,
        identity: Identity,
        provider: schema.AgentProvider,
        phase: ProxyPhase,
        protocol: ProxyProtocol,
        connection_id: u64,
        stream_id: u32,
        observed_at_ms: i64,
    ) bool {
        if (provider == .unknown) return false;
        var record = switch (phase) {
            .request_started => store.ensure(identity) orelse return false,
            .response_activity, .response_finished, .request_failed => store.find(identity.key) orelse return false,
        };
        const request: ProxyRequest = .{
            .protocol = protocol,
            .connection_id = connection_id,
            .stream_id = stream_id,
        };
        const tracked = switch (phase) {
            .request_started => markProxyActive(record, request),
            .response_activity => hasProxyActive(record, request),
            .response_finished, .request_failed => settleProxy(record, request),
        };
        // Starts are filtered to model-inference routes by the proxy. Ignore
        // response events without a matching start so auxiliary provider
        // traffic cannot create or settle agent work on its own.
        if (phase != .request_started and !tracked) return false;
        if (phase == .response_activity) if (record.proxy) |*evidence| {
            if (evidence.provider == provider and evidence.status == .working) {
                if (observed_at_ms - evidence.observed_at_ms < activity_refresh_ms)
                    return false;
                evidence.observed_at_ms = observed_at_ms;
                evidence.expires_at_ms = observed_at_ms + working_expiry_ms;
                return store.reproject(record, observed_at_ms);
            }
        };
        // An HTTP response completes one model exchange, not the agent turn.
        // Claude may execute tools and issue another request before it returns
        // to its input prompt. Only confirmed screen evidence may settle this
        // network work as ready.
        const status: schema.AgentStatus = switch (phase) {
            .request_started, .response_activity, .response_finished => .working,
            .request_failed => .failed,
        };
        record.proxy = .{
            .provider = provider,
            .status = status,
            .source = .proxy_tls,
            .confidence = switch (phase) {
                .request_started, .response_finished => 95,
                .response_activity => 90,
                .request_failed => 98,
            },
            .observed_at_ms = observed_at_ms,
            .expires_at_ms = observed_at_ms + if (status == .working)
                working_expiry_ms
            else
                settled_expiry_ms,
        };
        record.authority = if (record.authority == .obscured and
            (phase == .request_started or phase == .response_activity))
        resumed: {
            // Fresh network work proves that a previously visible permission
            // prompt no longer owns the session. Its bounded screen evidence
            // must not keep masking the resumed request.
            record.screen = null;
            break :resumed .resumed;
        } else switch (record.authority) {
            .candidate, .stale => .active,
            .active, .obscured, .resumed => record.authority,
            .exited => return false,
        };
        return store.reproject(record, observed_at_ms);
    }

    pub fn observeScreen(
        store: *Store,
        identity: Identity,
        signal: ScreenSignal,
        observed_at_ms: i64,
    ) bool {
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

    pub fn expire(store: *Store, now_ms: i64) bool {
        var changed = false;
        for (&store.records) |*slot| {
            var record = if (slot.*) |*value| value else continue;
            if (record.proxy) |evidence| {
                if (evidence.expires_at_ms <= now_ms) {
                    record.proxy = null;
                    clearProxyActive(record);
                }
            }
            if (record.screen) |evidence| {
                if (evidence.expires_at_ms <= now_ms) record.screen = null;
            }
            if (record.process == null and record.proxy == null and record.screen == null) {
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

    pub fn remove(store: *Store, key: PaneKey) bool {
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

    pub fn snapshot(
        store: *const Store,
        entries: *[max_records]schema.AgentSnapshotEntry,
    ) []const schema.AgentSnapshotEntry {
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

    pub fn projectedStatus(store: *const Store, key: PaneKey) ?schema.AgentStatus {
        for (&store.records) |*slot| {
            const record = if (slot.*) |*value| value else continue;
            if (sameKey(record.key, key)) return record.projected.status;
        }
        return null;
    }

    /// Captures only the first submitted request for an already identified
    /// agent. Callers gate this method on explicit description configuration.
    pub fn observeInput(store: *Store, key: PaneKey, bytes: []const u8) bool {
        const record = store.find(key) orelse return false;
        if (record.title.phase != .waiting_query) return false;
        if (!record.title.capture.feed(bytes)) return false;
        record.title.phase = .waiting_work;
        return true;
    }

    /// Starts one bounded job at a time. Invalid captured input deterministically
    /// becomes a failed placeholder and is never retried.
    pub fn nextDescriptionJob(store: *Store) ?description.Job {
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
    pub fn finishDescription(store: *Store, result: *const description.Result) bool {
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

    pub fn setManualTitle(store: *Store, key: PaneKey, value: []const u8) !bool {
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
    pub fn touch(store: *Store) void {
        store.bumpRevision();
    }

    fn ensure(store: *Store, identity: Identity) ?*Record {
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

    fn find(store: *Store, key: PaneKey) ?*Record {
        for (&store.records) |*slot| {
            const record = if (slot.*) |*value| value else continue;
            if (sameKey(record.key, key)) return record;
        }
        return null;
    }

    fn reproject(store: *Store, record: *Record, now_ms: i64) bool {
        const evidence = chooseEvidence(record, now_ms) orelse return false;
        const provider = if (record.process) |process|
            process.provider
        else if (evidence.provider != .unknown)
            evidence.provider
        else if (record.proxy) |proxy|
            proxy.provider
        else if (record.screen) |screen|
            screen.provider
        else
            .unknown;
        const previous = record.projected;
        ensurePlaceholder(record, provider);
        store.sequence +%= 1;
        if (store.sequence == 0) store.sequence = 1;
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

    fn advanceTitle(
        store: *const Store,
        record: *Record,
        status: schema.AgentStatus,
    ) bool {
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

    fn pendingDescriptionCount(store: *const Store) usize {
        var count: usize = 0;
        for (&store.records) |*slot| {
            const record = if (slot.*) |*value| value else continue;
            if (record.title.phase == .queued or record.title.phase == .running)
                count += 1;
        }
        return count;
    }

    fn bumpRevision(store: *Store) void {
        store.revision +%= 1;
        if (store.revision == 0) store.revision = 1;
    }
};

fn markProxyActive(record: *Record, request: ProxyRequest) bool {
    var free: ?*?ProxyRequest = null;
    for (&record.active_proxy) |*slot| {
        if (slot.*) |active| {
            if (sameProxyRequest(active, request)) return false;
        } else if (free == null) {
            free = slot;
        }
    }
    const destination = free orelse return false;
    destination.* = request;
    record.active_proxy_count += 1;
    return true;
}

fn hasProxyActive(record: *const Record, request: ProxyRequest) bool {
    for (record.active_proxy) |active|
        if (active != null and sameProxyRequest(active.?, request)) return true;
    return false;
}

fn settleProxy(record: *Record, request: ProxyRequest) bool {
    if (request.protocol == .h2 and request.stream_id == 0) {
        var removed = false;
        for (&record.active_proxy) |*slot| {
            const active = slot.* orelse continue;
            if (active.protocol != .h2 or active.connection_id != request.connection_id)
                continue;
            slot.* = null;
            record.active_proxy_count -= 1;
            removed = true;
        }
        return removed;
    }
    for (&record.active_proxy) |*slot| {
        const active = slot.* orelse continue;
        if (!sameProxyRequest(active, request)) continue;
        slot.* = null;
        record.active_proxy_count -= 1;
        return true;
    }
    return false;
}

fn clearProxyActive(record: *Record) void {
    record.active_proxy = @splat(null);
    record.active_proxy_count = 0;
}

fn sameProxyRequest(left: ProxyRequest, right: ProxyRequest) bool {
    return left.protocol == right.protocol and
        left.connection_id == right.connection_id and
        left.stream_id == right.stream_id;
}

fn chooseEvidence(record: *const Record, now_ms: i64) ?Evidence {
    const process = record.process;
    const screen = if (record.screen) |value|
        if (value.expires_at_ms > now_ms) value else null
    else
        null;
    const proxy = if (record.proxy) |value|
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

fn currentStatus(record: *const Record) schema.AgentStatus {
    return record.projected.status;
}

fn recordProvider(record: *const Record) schema.AgentProvider {
    if (record.process) |evidence| return evidence.provider;
    if (record.proxy) |evidence| if (evidence.provider != .unknown) return evidence.provider;
    if (record.screen) |evidence| return evidence.provider;
    return .unknown;
}

fn ensurePlaceholder(record: *Record, provider: schema.AgentProvider) void {
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

fn observeTestProxy(
    store: *Store,
    identity: Identity,
    provider: schema.AgentProvider,
    phase: ProxyPhase,
    observed_at_ms: i64,
) bool {
    return store.observeProxy(
        identity,
        provider,
        phase,
        .h2,
        1,
        1,
        observed_at_ms,
    );
}

fn observeTestReadyPrompt(
    store: *Store,
    identity: Identity,
    provider: schema.AgentProvider,
    observed_at_ms: i64,
) bool {
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

test "display context changes advance the public snapshot revision" {
    var store: Store = .{};
    const before = store.revision;
    store.touch();
    try std.testing.expectEqual(before + 1, store.revision);
}

test "only a confirmed prompt settles model work" {
    var store: Store = .{};
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
    var store: Store = .{};
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
    var store: Store = .{};
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
    var store: Store = .{};
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
    var store: Store = .{};
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
    var store: Store = .{};
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
    var store: Store = .{};
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
    var store: Store = .{};
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
    var store: Store = .{};
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
    var store: Store = .{};
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
    var store: Store = .{};
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
    var store: Store = .{};
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
    var store: Store = .{};
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
    var store: Store = .{};
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
    var store: Store = .{};
    const identity = try testIdentity();
    try std.testing.expect(!store.observeProxy(
        identity,
        .claude,
        .response_activity,
        .h2,
        9,
        3,
        100,
    ));
    try std.testing.expect(!store.observeProxy(
        identity,
        .claude,
        .request_failed,
        .h2,
        9,
        3,
        200,
    ));

    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    try std.testing.expectEqual(@as(usize, 0), store.snapshot(&entries).len);
}

test "expired agent evidence is removed" {
    var store: Store = .{};
    const identity = try testIdentity();
    try std.testing.expect(observeTestProxy(&store, identity, .codex, .request_started, 50));
    try std.testing.expect(observeTestProxy(&store, identity, .codex, .response_finished, 100));
    try std.testing.expect(store.expire(100 + settled_expiry_ms));
    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    try std.testing.expectEqual(@as(usize, 0), store.snapshot(&entries).len);
}

test "a bare shell prompt is not Claude identity" {
    var store: Store = .{};
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
    var store: Store = .{};
    const identity = try testIdentity();
    try std.testing.expect(store.observeProxy(
        identity,
        .codex,
        .request_started,
        .h2,
        9,
        1,
        100,
    ));
    _ = store.observeProxy(identity, .codex, .request_started, .h2, 9, 3, 101);
    _ = store.observeProxy(identity, .codex, .response_finished, .h2, 9, 1, 200);

    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    var snapshot = store.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentStatus.working, snapshot[0].status);
    _ = store.observeProxy(identity, .codex, .response_finished, .h2, 9, 3, 300);
    snapshot = store.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentStatus.working, snapshot[0].status);

    try std.testing.expect(observeTestReadyPrompt(&store, identity, .codex, 400));
    snapshot = store.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentStatus.ready, snapshot[0].status);
}

test "sequential model requests stay working until a confirmed prompt" {
    var store: Store = .{};
    const identity = try testIdentity();
    try std.testing.expect(store.observeProxy(
        identity,
        .claude,
        .request_started,
        .h2,
        9,
        1,
        100,
    ));
    try std.testing.expect(store.observeProxy(
        identity,
        .claude,
        .response_finished,
        .h2,
        9,
        1,
        200,
    ));

    var entries: [max_records]schema.AgentSnapshotEntry = undefined;
    var snapshot = store.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentStatus.working, snapshot[0].status);

    try std.testing.expect(store.observeProxy(
        identity,
        .claude,
        .request_started,
        .h2,
        9,
        3,
        300,
    ));
    try std.testing.expect(store.observeProxy(
        identity,
        .claude,
        .response_finished,
        .h2,
        9,
        3,
        400,
    ));
    snapshot = store.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentStatus.working, snapshot[0].status);

    try std.testing.expect(observeTestReadyPrompt(&store, identity, .claude, 500));
    snapshot = store.snapshot(&entries);
    try std.testing.expectEqual(schema.AgentStatus.ready, snapshot[0].status);
    try std.testing.expectEqual(schema.AgentSource.screen, snapshot[0].source);
}

test "HTTP2 connection failure settles all of its active streams" {
    var store: Store = .{};
    const identity = try testIdentity();
    _ = store.observeProxy(identity, .claude, .request_started, .h2, 11, 1, 100);
    _ = store.observeProxy(identity, .claude, .request_started, .h2, 11, 3, 101);
    try std.testing.expect(store.observeProxy(
        identity,
        .claude,
        .request_failed,
        .h2,
        11,
        0,
        200,
    ));
    try std.testing.expectEqual(@as(u16, 0), store.find(identity.key).?.active_proxy_count);
    try std.testing.expect(!store.observeProxy(
        identity,
        .claude,
        .request_failed,
        .h2,
        11,
        0,
        201,
    ));
}
