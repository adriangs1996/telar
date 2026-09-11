const FormatRequest = @This();
const source_namespace = @import("telemetry.zig");
const Metrics = @import("Metrics.zig");
const pace = @import("../../presentation/root.zig").pace;
const Snapshot = @import("Snapshot.zig");
io: source_namespace.Io,
metrics: *const Metrics,
pacer: *const pace.Pacer,
snapshot: Snapshot,
