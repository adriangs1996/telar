//! Runtime-owned trusted tap plugin capability.

pub const effects = @import("effects.zig");
pub const runWorker = @import("host_support.zig").run;
pub const protocol = @import("protocol.zig");
pub const service = @import("service_support.zig");

pub const EffectResult = effects.Result;
pub const Service = service.Service;
pub const Spec = service.Spec;
pub const max_workers = service.max_workers;

test {
    _ = effects;
    _ = @import("host_support.zig");
    _ = protocol;
    _ = service;
}
