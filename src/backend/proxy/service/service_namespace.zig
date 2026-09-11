//! Supported namespace for the runtime-owned loopback proxy service.

const implementation = @import("service_support.zig");
const std = @import("std");
const service_test = @import("service_test.zig");

pub const ClientConfiguration = @import("ClientConfiguration.zig");
pub const max_connections = implementation.max_connections;
pub const Pane = @import("Pane.zig");
pub const Paths = @import("Paths.zig");
pub const Service = @import("Service.zig");
pub const Worker = implementation.Worker;

test {
    std.testing.refAllDecls(implementation);
    _ = service_test;
}
