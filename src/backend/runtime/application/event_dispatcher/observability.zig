//! Runtime-event adapters for metrics sampling and telemetry delivery.

const std = @import("std");
const attachment_mod = @import("../../attachment/root.zig");
const client_store = @import("../../client/root.zig").store;
const event_sources = @import("../../event_sources.zig");
const observability = @import("../../observability/root.zig");

pub const Io = std.Io;

pub const AttachmentStore = attachment_mod.AttachmentStore;
pub const TelemetryState = observability.telemetry.State;
pub const formatRuntimeTelemetry = observability.telemetry.formatRuntimeTelemetry;
pub const max_clients = client_store.max_clients;
pub const system_metrics_mod = observability.system_metrics;
pub const system_metrics_coordinator = observability.system_metrics_coordinator;
pub const telemetry_mod = observability.telemetry;
pub const telemetry_tick_coordinator = observability.telemetry_tick_coordinator;

pub const Dispatcher = @import("GenericObservabilityDispatcher.zig").Type;

test {
    std.testing.refAllDecls(@This());
}
