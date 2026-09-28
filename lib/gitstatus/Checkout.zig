const std = @import("std");
/// A checkout Git measures and the environment Git runs with there.
const Checkout = @This();

/// The runtime's environment; Git gets it with its hardening added.
environ: std.process.Environ,
path: []const u8,
