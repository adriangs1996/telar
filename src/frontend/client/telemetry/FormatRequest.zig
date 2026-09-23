const client = @import("telar-client");
const core = @import("telar-core");
const std = @import("std");
const Snapshot = @import("Snapshot.zig");
const FormatRequest = @This();

io: std.Io,
metrics: *const client.TelemetryMetrics,
pacer: *const core.Pacer,
snapshot: Snapshot,
