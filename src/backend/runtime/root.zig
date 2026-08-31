//! Public namespace for one long-lived Telar runtime.

const instance = @import("instance.zig");
const observability = @import("observability/root.zig");

pub const GraphicsLimits = instance.GraphicsLimits;
pub const ServeOptions = instance.ServeOptions;
pub const AgentDescriptionOptions = instance.AgentDescriptionOptions;
pub const ProxyOptions = instance.ProxyOptions;
pub const ClientKey = instance.ClientKey;
pub const IngestTestGate = instance.IngestTestGate;
pub const LaunchTestFault = instance.LaunchTestFault;
pub const system_metrics = observability.system_metrics;
pub const serve = instance.serve;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("tests/root.zig");
}
