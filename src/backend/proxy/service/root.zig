//! Supported namespace for the runtime-owned loopback proxy service.

const std = @import("std");
const implementation = @import("service.zig");

pub const ClientConfiguration = implementation.ClientConfiguration;
pub const max_connections = implementation.max_connections;
pub const Pane = implementation.Pane;
pub const Paths = implementation.Paths;
pub const Service = implementation.Service;
pub const Worker = implementation.Worker;

test {
    std.testing.refAllDecls(implementation);
    _ = @import("service_test.zig");
}
