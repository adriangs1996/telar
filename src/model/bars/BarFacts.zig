//! Host facts built-in components show: the latest runtime metrics, recent
//! CPU samples, the local time the clock components format and the
//! window's machines.
const LocalTime = @import("../state/LocalTime.zig");
const SystemMetrics = @import("../state/SystemMetrics.zig");
const MachineFact = @import("MachineFact.zig");
const BarFacts = @This();

metrics: ?SystemMetrics = null,
/// CPU percentages, oldest first.
cpu: []const u8 = &.{},
now: LocalTime = .epoch,
/// The window's machines in slot order; empty while it holds one.
machines: []const MachineFact = &.{},
