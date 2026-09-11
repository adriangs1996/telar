//! Routes runtime event completions to their owning application capability.

const std = @import("std");
const pane_mod = @import("../../../pane/root.zig");
pub const Pane = pane_mod.Pane;
const runtime_config = @import("../../config.zig");
const runtime_event = @import("../../event.zig");
const agent_event_dispatcher = @import("agent.zig");
const client_event_dispatcher = @import("client.zig");
const history_event_dispatcher = @import("history.zig");
const observability_event_dispatcher = @import("observability.zig");
const pane_event_dispatcher = @import("pane/root.zig");
const observability = @import("../../observability/root.zig");
const transport = @import("../../../transport/root.zig");

pub const TelemetryState = observability.telemetry.State;

pub const IngestTestGate = runtime_config.IngestTestGate;
pub const RuntimeEvent = runtime_event.Event;

pub const Dispatcher = @import("GenericEventDispatcherDispatcher.zig").Type;

test {
    std.testing.refAllDecls(@This());
}
