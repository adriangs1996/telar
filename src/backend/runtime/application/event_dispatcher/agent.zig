//! Runtime-event adapters that mutate the agent aggregate.

const std = @import("std");
const agent_mod = @import("../../../agent/root.zig");
const engine = @import("../../../engine/root.zig");
const proxy_mod = @import("../../../proxy/root.zig");
const plugins = @import("../../../plugins/root.zig");
const delivery_mod = @import("../../delivery/root.zig");
const suggestion = @import("../suggestion.zig");
const runtime_event_entrypoints = @import("../../entrypoints/events/root.zig");
const event_sources = @import("../../event_sources.zig");
const coordinators = @import("../coordinators/root.zig");

pub const Io = std.Io;

pub const agent_description_coordinator = coordinators.agent_description;
pub const agent_maintenance_coordinator = coordinators.agent_maintenance;
pub const proxy_observation_adapter = runtime_event_entrypoints.proxy_observation;
pub const proxy_capture_adapter = runtime_event_entrypoints.proxy_capture;
pub const plugin_effects_adapter = runtime_event_entrypoints.plugin_effects;

pub const Dispatcher = @import("GenericAgentDispatcher.zig").Type;

test {
    std.testing.refAllDecls(@This());
}
