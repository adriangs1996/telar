const std = @import("std");
const WorktreeProbe = @import("../../workspace/WorktreeProbe.zig");
const WorktreeProbeJob = @This();

io: std.Io,
/// The runtime's environment, which Git gets with its hardening added.
environ: std.process.Environ,
request: WorktreeProbe,
