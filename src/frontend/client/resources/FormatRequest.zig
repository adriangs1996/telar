const core = @import("telar-core");
const std = @import("std");
const Metrics = @import("telar-client").TelemetryMetrics;
const PacerType = core.Pacer;
const Snapshot = @import("Snapshot.zig");
const FormatRequest = @This();

io: std.Io,
metrics: *const Metrics,
pacer: *const PacerType,
snapshot: Snapshot,
