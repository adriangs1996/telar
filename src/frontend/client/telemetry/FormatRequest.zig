const pacing = @import("pacing");
const client = @import("telar-client");
const std = @import("std");
const Snapshot = @import("Snapshot.zig");
const FormatRequest = @This();

io: std.Io,
metrics: *const client.TelemetryMetrics,
pacer: *const pacing.Pacer,
snapshot: Snapshot,
