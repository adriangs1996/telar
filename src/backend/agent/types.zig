//! Values accepted and published by the agent capability.

const std = @import("std");
const core = @import("telar-core");
const detection = @import("../history/root.zig").detection;
const dialect_mod = @import("../proxy/provider/dialect.zig");
const pane_mod = @import("../pane/root.zig");

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
pub const ApiDialect = dialect_mod.ApiDialect;

pub const Identity = struct {
    key: PaneKey,
    process_id: u32,
    session_id: [16]u8,

    /// Captures the pane generation and process identity owned by one agent.
    ///
    /// ```zig
    /// const identity = Identity.fromPane(pane);
    /// ```
    pub fn fromPane(pane: *const Pane) Identity {
        return .{
            .key = pane.key(),
            .process_id = std.math.cast(u32, pane.session.processId()) orelse 0,
            .session_id = pane.history_session_id,
        };
    }
};

pub const ProcessObservation = struct {
    identity: Identity,
    provider: schema.AgentProvider,
    process_id: u32,
    observed_at_ms: i64,
};

pub const ScreenObservation = struct {
    identity: Identity,
    signal: ScreenSignal,
    observed_at_ms: i64,
};

/// An agent's own session identifier as reported through the control API,
/// typed and bounded so restore can rebuild a fixed argv from it.
pub const SessionReference = struct {
    bytes: [schema.max_agent_session_reference_bytes]u8 = undefined,
    len: u8 = 0,
    observed_at_ms: i64 = 0,

    pub fn slice(reference: *const SessionReference) []const u8 {
        return reference.bytes[0..reference.len];
    }

    /// Copies a validated reference.
    ///
    /// ```zig
    /// const reference = try SessionReference.init("0192...", now_ms);
    /// ```
    pub fn init(value: []const u8, observed_at_ms: i64) !SessionReference {
        try schema.validateSessionReference(value);
        var reference: SessionReference = .{ .observed_at_ms = observed_at_ms };
        @memcpy(reference.bytes[0..value.len], value);
        reference.len = @intCast(value.len);
        return reference;
    }
};

/// A ready session title with the source that produced it, bounded so the
/// checkpoint can carry it and restore can hand it back to a resumed agent.
pub const SessionTitle = struct {
    bytes: [schema.max_agent_session_title_bytes]u8 = undefined,
    len: u8 = 0,
    source: schema.AgentTitleSource,

    pub fn slice(title: *const SessionTitle) []const u8 {
        return title.bytes[0..title.len];
    }

    /// Copies a validated title. Only generated and manual titles are durable;
    /// placeholders and a child's own window title are never stored.
    ///
    /// ```zig
    /// const title = try SessionTitle.init("Investigate proxy lifecycle", .generated);
    /// ```
    pub fn init(value: []const u8, source: schema.AgentTitleSource) !SessionTitle {
        if (source != .generated and source != .manual) {
            return error.InvalidSessionTitle;
        }

        try schema.validateSessionTitle(value);
        var title: SessionTitle = .{ .source = source };
        @memcpy(title.bytes[0..value.len], value);
        title.len = @intCast(value.len);
        return title;
    }
};

/// One official lifecycle report from the agent's own hooks.
pub const ReportObservation = struct {
    identity: Identity,
    state: schema.AgentReportState,
    observed_at_ms: i64,
    session: ?SessionReference = null,
};

pub const ProxyPhase = enum {
    request_started,
    response_activity,
    provider_turn_completed,
    response_finished,
    request_failed,
};

pub const ProxyProtocol = enum { http11, h2, upgraded };

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
/// `observed_at_ms` orders evidence and determines its expiry. `dialect` names
/// the API family seen on the wire, never the agent process. Callers exclude
/// auxiliary traffic before constructing this value.
pub const ProxyObservation = struct {
    identity: Identity,
    dialect: ApiDialect,
    phase: ProxyPhase,
    exchange: ProxyExchange,
    observed_at_ms: i64,

    /// The built-in agent implied by the wire dialect. It is an identity only
    /// while no process has claimed the pane; see `ApiDialect.impliedAgent`.
    ///
    /// ```zig
    /// if (observation.impliedProvider() == evidence.provider) {
    ///     refreshActivity();
    /// }
    /// ```
    pub fn impliedProvider(observation: *const ProxyObservation) schema.AgentProvider {
        return observation.dialect.impliedAgent();
    }

    /// Reports whether this observation carries response bytes without closing
    /// the exchange.
    ///
    /// ```zig
    /// if (observation.isResponseActivity()) {
    ///     coalesceActivity();
    /// }
    /// ```
    pub fn isResponseActivity(observation: *const ProxyObservation) bool {
        return observation.phase == .response_activity;
    }
};

/// Owned title projection emitted only after the agent aggregate accepts and
/// validates a description result.
pub const DescriptionFinished = struct {
    pane: PaneKey,
    session_id: [16]u8,
    title: [schema.max_agent_session_title_bytes]u8 = undefined,
    title_len: u8 = 0,
    source: schema.AgentTitleSource,
    state: schema.AgentTitleState,

    /// Returns the title bytes owned by this completion event.
    ///
    /// ```zig
    /// try persist(finished.titleSlice());
    /// ```
    pub fn titleSlice(finished: *const DescriptionFinished) []const u8 {
        return finished.title[0..finished.title_len];
    }
};
