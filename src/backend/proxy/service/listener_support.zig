//! Bounded loopback listener for the local proxy capability.

const std = @import("std");

pub const first_port: u16 = 45100;
pub const port_attempts: u16 = 128;
/// A set of proxy ports, each one its offset from `first_port`.
pub const PortSet = std.StaticBitSet(port_attempts);
