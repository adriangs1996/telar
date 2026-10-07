const std = @import("std");
const Probe = @import("../../workspace/Probe.zig");

io: std.Io,
/// The runtime's environment, which Git gets with its hardening added.
environ: std.process.Environ,
request: Probe,
