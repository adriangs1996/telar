//! Values accepted and published by the agent capability.

const std = @import("std");
const core = @import("telar-core");
const detection = @import("../history/root.zig").detection;
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
            .process_id = std.math.cast(u32, pane.session.pid) orelse 0,
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
/// `observed_at_ms` orders evidence and determines its expiry. Callers exclude
/// auxiliary provider traffic before constructing this value.
pub const ProxyObservation = struct {
    identity: Identity,
    provider: schema.AgentProvider,
    phase: ProxyPhase,
    exchange: ProxyExchange,
    observed_at_ms: i64,

    /// Compares the observed provider with an established provider identity.
    ///
    /// ```zig
    /// if (observation.hasProvider(.claude)) {
    ///     refreshClaudeActivity();
    /// }
    /// ```
    pub fn hasProvider(observation: *const ProxyObservation, provider: schema.AgentProvider) bool {
        return observation.provider == provider;
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
