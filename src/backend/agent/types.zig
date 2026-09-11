//! Values accepted and published by the agent capability.

const ProxyObservation = @import("ProxyObservation.zig");
const std = @import("std");
const AgentProviderType = @import("telar-core").AgentProvider;

test "agent policy interprets neutral wire dialects without importing a proxy adapter" {
    var observation: ProxyObservation = undefined;
    observation.dialect = .anthropic_messages;
    try std.testing.expectEqual(AgentProviderType.claude, observation.impliedProvider());
    observation.dialect = .openai_responses;
    try std.testing.expectEqual(AgentProviderType.codex, observation.impliedProvider());
    observation.dialect = .unknown;
    try std.testing.expectEqual(AgentProviderType.unknown, observation.impliedProvider());
}

pub const working_expiry_ms: i64 = 2 * 60 * 1000;
pub const settled_expiry_ms: i64 = 30 * 60 * 1000;
pub const activity_refresh_ms: i64 = 5 * 1000;
pub const max_active_proxy_requests = 128;

/// Wire vocabulary accepted by agent observations, not a process identity.
pub const ApiDialect = enum(u8) {
    unknown = 0,
    anthropic_messages = 1,
    openai_responses = 2,
};

pub const ProxyPhase = enum {
    request_started,
    response_activity,
    provider_turn_completed,
    response_finished,
    request_failed,
};

pub const ProxyProtocol = enum { http11, h2, upgraded };
