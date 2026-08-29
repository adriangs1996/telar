//! Public namespace for runtime-owned agent observation and projection.
//!
//! Callers submit typed observations to `Registry`. Aggregate state, evidence
//! precedence, proxy tracking, and title lifecycle remain implementation
//! details of this capability.

const registry = @import("registry.zig");
const types = @import("types.zig");

pub const description = @import("description.zig");
pub const Registry = registry.Registry;

pub const max_records = types.max_records;
pub const ScreenStatus = types.ScreenStatus;
pub const ScreenSignal = types.ScreenSignal;
pub const Identity = types.Identity;
pub const ProcessObservation = types.ProcessObservation;
pub const ScreenObservation = types.ScreenObservation;
pub const ProxyPhase = types.ProxyPhase;
pub const ProxyProtocol = types.ProxyProtocol;
pub const ProxyExchange = types.ProxyExchange;
pub const ProxyObservation = types.ProxyObservation;

test {
    _ = @import("agent.zig");
    _ = @import("evidence.zig");
    _ = @import("proxy_state.zig");
    _ = @import("registry.zig");
}
