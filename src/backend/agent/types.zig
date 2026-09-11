//! Values accepted and published by the agent capability.

const std = @import("std");
const core = @import("telar-core");
const pane_mod = @import("../pane/root.zig");

pub const schema = core.schema;
pub const PaneKey = pane_mod.PaneKey;

test "agent policy interprets neutral wire dialects without importing a proxy adapter" {
    var observation: ProxyObservation = undefined;
    observation.dialect = .anthropic_messages;
    try std.testing.expectEqual(schema.AgentProvider.claude, observation.impliedProvider());
    observation.dialect = .openai_responses;
    try std.testing.expectEqual(schema.AgentProvider.codex, observation.impliedProvider());
    observation.dialect = .unknown;
    try std.testing.expectEqual(schema.AgentProvider.unknown, observation.impliedProvider());
}

pub const max_records = schema.max_agent_snapshot_entries;
pub const working_expiry_ms: i64 = 2 * 60 * 1000;
pub const settled_expiry_ms: i64 = 30 * 60 * 1000;
pub const activity_refresh_ms: i64 = 5 * 1000;
pub const max_active_proxy_requests = 128;

pub const ScreenStatus = core.agent_manifest.Status;
pub const ScreenSignal = core.agent_manifest.Signal;
/// Wire vocabulary accepted by agent observations, not a process identity.
pub const ApiDialect = enum(u8) {
    unknown = 0,
    anthropic_messages = 1,
    openai_responses = 2,
};

pub const Identity = @import("Identity.zig");

pub const ProcessObservation = @import("ProcessObservation.zig");

pub const ScreenObservation = @import("ScreenObservation.zig");

pub const SessionReference = @import("SessionReference.zig");

pub const SessionTitle = @import("SessionTitle.zig");

pub const SessionFile = @import("SessionFile.zig");

pub const ReportObservation = @import("ReportObservation.zig");

pub const ProxyPhase = enum {
    request_started,
    response_activity,
    provider_turn_completed,
    response_finished,
    request_failed,
};

pub const ProxyProtocol = enum { http11, h2, upgraded };

pub const ProxyExchange = @import("ProxyExchange.zig");

pub const ProxyObservation = @import("ProxyObservation.zig");

pub const DescriptionFinished = @import("DescriptionFinished.zig");
