const std = @import("std");
const Metrics = @import("Metrics.zig");
const PacerType = @import("../../presentation/Pacer.zig");
const Snapshot = @import("Snapshot.zig");
const FormatRequest = @This();

io: std.Io,
metrics: *const Metrics,
pacer: *const PacerType,
snapshot: Snapshot,
