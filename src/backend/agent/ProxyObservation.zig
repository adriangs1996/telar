const Identity = @import("Identity.zig");
const types = @import("types.zig");
const ProxyExchange = @import("ProxyExchange.zig");
const AgentProviderType = @import("telar-core").AgentProvider;
/// Owned proxy evidence enriched by the runtime with the exact agent identity
/// that was active when the observation arrived.
///
/// The exchange identifies the network work being observed, while
/// `observed_at_ms` orders evidence and determines its expiry. `dialect` names
/// the API family seen on the wire, never the agent process. Callers exclude
/// auxiliary traffic before constructing this value.
const ProxyObservation = @This();

identity: Identity,
dialect: types.ApiDialect,
phase: types.ProxyPhase,
exchange: ProxyExchange,
observed_at_ms: i64,

/// The built-in agent implied by the wire dialect. It is an identity only
/// while no process has claimed the pane.
///
/// ```zig
/// if (observation.impliedProvider() == evidence.provider) {
///     refreshActivity();
/// }
/// ```
pub fn impliedProvider(observation: *const ProxyObservation) AgentProviderType {
    return switch (observation.dialect) {
        .unknown => .unknown,
        .anthropic_messages => .claude,
        .openai_responses => .codex,
    };
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
