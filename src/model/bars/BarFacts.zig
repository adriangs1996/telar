//! Host facts built-in components show: the latest runtime metrics, recent
//! CPU samples and the local time the clock components format.
const LocalTime = @import("../state/LocalTime.zig");
const SystemMetrics = @import("../state/SystemMetrics.zig");
const BarFacts = @This();

metrics: ?SystemMetrics = null,
/// CPU percentages, oldest first.
cpu: []const u8 = &.{},
now: LocalTime = .epoch,
